/*
 * gen_rtl_vectors.c
 *
 * Produces bit-exact test vectors for the SystemVerilog AAA engine by
 * replaying the C reference engine over the 400 rounds in
 * sim/output/reference_run.csv.
 *
 * Outputs (under tb/vectors/):
 *   payload_<round>.hex    one byte per line, $readmemh format
 *   prng_<round>.hex       32 PRNG outputs per bob_received round
 *   selected_<round>.hex   16 selected bytes per bob_received round
 *   key_<round>.hex        16-byte key register after this round
 *   manifest.csv           per-round bob_rx / eve_rx / key_secure
 *
 * Build:
 *   gcc -O2 -Wall -I.. -o gen_rtl_vectors gen_rtl_vectors.c ../aaa_key_engine.c -lm
 *
 * Run (from repo root):
 *   ./tools/gen_rtl_vectors sim/output/reference_run.csv tb/vectors
 */

#include "../aaa_key_engine.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>

#define PAYLOAD_BYTES 512
#define MAX_ROUNDS    1024
#define PUBLIC_SEED   0xABCD1234u

/* Local xorshift32 used only for payload byte generation. Separate from the
 * AAA engine's PRNG so test payloads are reproducible by any consumer
 * (Python HIL script, RTL TB, etc.) without depending on libc rand(). */
static uint32_t xs32(uint32_t *s) {
    uint32_t x = *s;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *s = x;
    return x;
}

static void gen_payload(uint32_t round, uint8_t out[PAYLOAD_BYTES]) {
    uint32_t s = (round != 0) ? round : 0xDEADBEEFu;
    /* Advance a few times to decorrelate from the small seed. */
    for (int k = 0; k < 4; k++) (void)xs32(&s);
    for (int i = 0; i < PAYLOAD_BYTES; i += 4) {
        uint32_t r = xs32(&s);
        out[i + 0] = (uint8_t)(r      );
        out[i + 1] = (uint8_t)(r >>  8);
        out[i + 2] = (uint8_t)(r >> 16);
        out[i + 3] = (uint8_t)(r >> 24);
    }
}

/* Mirrors prng_xorshift32 in aaa_key_engine.c — must stay byte-identical. */
static uint32_t aaa_prng(uint32_t *state) {
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

/* Reimplements select_bits_from_payload but captures the PRNG/selected
 * trace into the provided buffers. The math must match aaa_key_engine.c. */
static void instrumented_select(uint32_t  *prng_state,
                                const uint8_t *payload,
                                size_t         payload_len,
                                uint8_t        selected[AAA_KEY_BYTES],
                                uint32_t       prng_trace[AAA_KEY_BYTES * 2])
{
    memset(selected, 0, AAA_KEY_BYTES);
    for (int l = 0; l < AAA_KEY_BYTES; l++) {
        uint32_t r1 = aaa_prng(prng_state);
        size_t  i1 = (size_t)(r1 % (uint32_t)payload_len);
        selected[l] = payload[i1];
        prng_trace[2*l + 0] = r1;

        uint32_t r2 = aaa_prng(prng_state);
        size_t  i2 = (size_t)(r2 % (uint32_t)payload_len);
        selected[l] ^= payload[i2];
        prng_trace[2*l + 1] = r2;
    }
}

static int write_hex_bytes(const char *path, const uint8_t *buf, size_t n) {
    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "open %s: ", path); perror(""); return -1; }
    for (size_t i = 0; i < n; i++) fprintf(f, "%02X\n", buf[i]);
    fclose(f);
    return 0;
}

static int write_hex_words(const char *path, const uint32_t *buf, size_t n) {
    FILE *f = fopen(path, "w");
    if (!f) { fprintf(stderr, "open %s: ", path); perror(""); return -1; }
    for (size_t i = 0; i < n; i++) fprintf(f, "%08X\n", buf[i]);
    fclose(f);
    return 0;
}

static int ensure_dir(const char *path) {
#if defined(_WIN32)
    return mkdir(path);
#else
    return mkdir(path, 0775);
#endif
}

int main(int argc, char **argv) {
    /* Defaults assume the full 400-round table from aaa_sweep.py. The CSV
     * mixes engines and distances; we filter to the preferred engine at
     * the reference distance. reference_run.csv is also accepted as input
     * but contains only the first 12 rows in the current repo state. */
    const char *csv_path        = (argc > 1) ? argv[1] : "sim/output/sweep_rounds.csv";
    const char *out_dir         = (argc > 2) ? argv[2] : "tb/vectors";
    const char *filter_engine   = (argc > 3) ? argv[3] : "ns3";
    float       filter_distance = (argc > 4) ? (float)atof(argv[4]) : 45.0f;

    if (AAA_KEY_BYTES != 16) {
        fprintf(stderr, "This generator assumes AAA_KEY_BYTES==16. Got %d.\n",
                AAA_KEY_BYTES);
        return 1;
    }

    ensure_dir(out_dir);

    FILE *csv = fopen(csv_path, "r");
    if (!csv) {
        fprintf(stderr, "Cannot open %s: ", csv_path);
        perror("");
        return 1;
    }

    /* Skip header line. */
    char line[1024];
    if (!fgets(line, sizeof(line), csv)) {
        fprintf(stderr, "Empty CSV.\n");
        fclose(csv);
        return 1;
    }

    aaa_ctx_t ctx;
    aaa_init(&ctx, PUBLIC_SEED);

    char manifest_path[512];
    snprintf(manifest_path, sizeof(manifest_path), "%s/manifest.csv", out_dir);
    FILE *manifest = fopen(manifest_path, "w");
    if (!manifest) { fprintf(stderr, "Cannot open %s\n", manifest_path); fclose(csv); return 1; }
    fprintf(manifest, "round,bob_rx,eve_rx,key_secure_after_round,key_hex\n");

    /* Simpler TB-side manifest: just the Bob-received rounds with eve flag. */
    char bobonly_path[512];
    snprintf(bobonly_path, sizeof(bobonly_path), "%s/bob_rounds.txt", out_dir);
    FILE *bobonly = fopen(bobonly_path, "w");
    if (!bobonly) { fprintf(stderr, "Cannot open %s\n", bobonly_path); fclose(csv); fclose(manifest); return 1; }

    int total_rounds_seen = 0;
    int bob_rounds_dumped = 0;
    int key_secure_latched = 0;

    while (fgets(line, sizeof(line), csv)) {
        char engine[32];
        float dist;
        int round, bob_rx, eve_rx, secure_round, key_sec_after;
        int cum_bob, cum_secure;
        float cum_eq;
        int parsed = sscanf(line, "%31[^,],%f,%d,%d,%d,%d,%d,%d,%d,%f",
                            engine, &dist, &round, &bob_rx, &eve_rx,
                            &secure_round, &key_sec_after,
                            &cum_bob, &cum_secure, &cum_eq);
        if (parsed < 7) continue;
        /* Filter to the requested engine + distance slice. */
        if (strcmp(engine, filter_engine) != 0) continue;
        if (dist < filter_distance - 0.01f || dist > filter_distance + 0.01f) continue;
        total_rounds_seen++;

        /* Generate this round's payload deterministically. */
        uint8_t payload[PAYLOAD_BYTES];
        gen_payload((uint32_t)round, payload);

        /* Always dump the payload — HIL replays every Bob-received round. */
        char path[768];
        snprintf(path, sizeof(path), "%s/payload_%04d.hex", out_dir, round);
        write_hex_bytes(path, payload, PAYLOAD_BYTES);

        if (bob_rx) {
            /* Drive the C engine and capture trace. */
            uint8_t  selected[AAA_KEY_BYTES];
            uint32_t prng_trace[AAA_KEY_BYTES * 2];
            instrumented_select(&ctx.prng_state, payload, PAYLOAD_BYTES,
                                selected, prng_trace);
            for (int l = 0; l < AAA_KEY_BYTES; l++) ctx.key[l] ^= selected[l];
            ctx.packets_total++;

            if (bob_rx && !eve_rx) {
                ctx.packets_missed_by_eve++;
                ctx.perfect_secrecy_achieved = true;
                key_secure_latched = 1;
            }

            snprintf(path, sizeof(path), "%s/prng_%04d.hex", out_dir, round);
            write_hex_words(path, prng_trace, AAA_KEY_BYTES * 2);

            snprintf(path, sizeof(path), "%s/selected_%04d.hex", out_dir, round);
            write_hex_bytes(path, selected, AAA_KEY_BYTES);

            snprintf(path, sizeof(path), "%s/key_%04d.hex", out_dir, round);
            write_hex_bytes(path, ctx.key, AAA_KEY_BYTES);

            fprintf(bobonly, "%d %d\n", round, eve_rx ? 1 : 0);

            bob_rounds_dumped++;
        }

        /* Manifest row (always emitted, key_hex is post-round state). */
        fprintf(manifest, "%d,%d,%d,%d,", round, bob_rx, eve_rx, key_secure_latched);
        for (int i = 0; i < AAA_KEY_BYTES; i++) fprintf(manifest, "%02X", ctx.key[i]);
        fprintf(manifest, "\n");
    }

    fclose(csv);
    fclose(manifest);
    fclose(bobonly);

    /* Also drop the final key for whole-run sanity. */
    char final_path[512];
    snprintf(final_path, sizeof(final_path), "%s/final_key.hex", out_dir);
    write_hex_bytes(final_path, ctx.key, AAA_KEY_BYTES);

    printf("[gen_rtl_vectors] rounds=%d bob_received=%d  key_secure_latched=%s\n",
           total_rounds_seen, bob_rounds_dumped,
           key_secure_latched ? "yes" : "no");
    printf("[gen_rtl_vectors] final key: ");
    for (int i = 0; i < AAA_KEY_BYTES; i++) printf("%02X", ctx.key[i]);
    printf("\n");
    printf("[gen_rtl_vectors] manifest: %s\n", manifest_path);
    return 0;
}
