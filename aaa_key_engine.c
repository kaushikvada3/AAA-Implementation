/**
 * aaa_key_engine.c
 *
 * Implementation of the AAA Secret-Key Generation Engine.
 * Designed to be portable across embedded MCUs (ARM Cortex-M, AVR,
 * ESP32, RISC-V, etc.) with no dynamic memory allocation and
 * minimal dependencies (only stdint, stddef, stdbool, stdio for debug).
 */

#include "aaa_key_engine.h"
#include <string.h>   /* memset, memcpy */
#include <stdio.h>    /* printf (debug only) */
#include <math.h>     /* expf (eve miss estimate) */

/* ── Internal PRNG ─────────────────────────────────────────────────────────
 * Xorshift32 — extremely lightweight, fits in a single register.
 * Both Alice and Bob use the same seed → same bit-selection sequence.
 * This is the "public protocol" described in the paper (Section I).
 * -------------------------------------------------------------------------- */
static uint32_t prng_xorshift32(uint32_t *state)
{
    uint32_t x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    return x;
}

/* ── Bit Selection ─────────────────────────────────────────────────────────
 * Selects AAA_KEY_BYTES bytes from the payload using the PRNG to
 * determine which byte positions to sample.
 *
 * This implements the protocol: "Xl,i = lth bit chosen according to
 * a public protocol from the random payload of the ith packet."
 *
 * Strategy: use PRNG to generate byte offsets into the payload,
 * then XOR-fold those bytes into the selection buffer so the
 * selected bits are spread uniformly across the payload.
 * -------------------------------------------------------------------------- */
static void select_bits_from_payload(uint32_t      *prng_state,
                                     const uint8_t *payload,
                                     size_t         payload_len,
                                     uint8_t       *out_selected)
{
    memset(out_selected, 0, AAA_KEY_BYTES);

    for (size_t l = 0; l < AAA_KEY_BYTES; l++) {
        /* Generate a pseudo-random index into the payload for each key byte */
        uint32_t rnd   = prng_xorshift32(prng_state);
        size_t   idx   = (size_t)(rnd % (uint32_t)payload_len);
        out_selected[l] = payload[idx];

        /* Optional: mix in a second byte for better diffusion */
        uint32_t rnd2  = prng_xorshift32(prng_state);
        size_t   idx2  = (size_t)(rnd2 % (uint32_t)payload_len);
        out_selected[l] ^= payload[idx2];
    }
}

/* ── Public API Implementation ─────────────────────────────────────────── */

aaa_status_t aaa_init(aaa_ctx_t *ctx, uint32_t public_seed)
{
    if (ctx == NULL) return AAA_ERR_NULL_PTR;

    memset(ctx, 0, sizeof(aaa_ctx_t));

    /* PRNG must not be seeded with 0 (Xorshift32 would lock up) */
    ctx->prng_state = (public_seed != 0) ? public_seed : 0xDEADBEEFu;

    return AAA_OK;
}

aaa_status_t aaa_process_packet(aaa_ctx_t    *ctx,
                                const uint8_t *payload,
                                size_t         payload_len,
                                bool           eve_missed_this)
{
    if (ctx == NULL || payload == NULL)  return AAA_ERR_NULL_PTR;
    if (payload_len < AAA_KEY_BYTES)     return AAA_ERR_BAD_PAYLOAD;

    /* Step 1: Select L bits from this packet using the public protocol */
    select_bits_from_payload(&ctx->prng_state,
                              payload,
                              payload_len,
                              ctx->_selected);

    /* Step 2: XOR accumulate into the key register — the entire AAA operation.
     *
     *   Kl,n = Xl,1 XOR Xl,2 XOR ... XOR Xl,n
     *
     * This is a single pass over AAA_KEY_BYTES bytes.
     * On a 32-bit MCU this loop is typically 4 instructions per 4-byte word.
     */
    for (size_t l = 0; l < AAA_KEY_BYTES; l++) {
        ctx->key[l] ^= ctx->_selected[l];
    }

    /* Step 3: Update statistics */
    ctx->packets_total++;

    if (eve_missed_this) {
        ctx->packets_missed_by_eve++;
        ctx->perfect_secrecy_achieved = true;  /* Theorem 1 condition met */
    }

    /* Clear scratch buffer so key material doesn't linger in RAM */
    memset(ctx->_selected, 0, AAA_KEY_BYTES);

    return AAA_OK;
}

bool aaa_estimate_eve_miss(float snr_user_db, uint32_t rate_bps)
{
    /*
     * Simple model based on the paper's packet loss equation (Section III-B):
     *
     *   μ_E = 1 - exp(-(2^R - 1) / (p * γ²))
     *
     * Here we estimate γ² (Eve's relative channel power) conservatively
     * as 0.5 (Eve is assumed to be at a similar distance as the user).
     * If Eve's SNR is significantly lower than the user's, the miss
     * probability rises quickly.
     *
     * In practice: replace this with real RSSI/SNR feedback from your
     * radio stack (e.g., ESP-IDF, LoRaWAN stack, 802.11 driver).
     *
     * Returns true if estimated miss probability > 5%.
     */
    (void)rate_bps; /* rate used in advanced model — simplified here */

    /* Convert SNR dB → linear power ratio */
    float snr_linear = powf(10.0f, snr_user_db / 10.0f);

    /* Assume Eve's SNR is ≤ 50% of user's SNR (conservative) */
    float eve_snr    = snr_linear * 0.5f;

    /* Packet error rate at Eve using simplified AWGN approximation */
    float threshold  = 1.0f; /* normalized threshold */
    float mu_eve     = 1.0f - expf(-threshold / (eve_snr + 1e-6f));

    /* Return true if Eve likely missed the packet */
    return (mu_eve > 0.05f);
}

aaa_status_t aaa_get_key(const aaa_ctx_t *ctx, uint8_t *out_key)
{
    if (ctx == NULL || out_key == NULL) return AAA_ERR_NULL_PTR;
    if (ctx->packets_total == 0)        return AAA_ERR_NOT_READY;

    memcpy(out_key, ctx->key, AAA_KEY_BYTES);
    return AAA_OK;
}

aaa_status_t aaa_get_stats(const aaa_ctx_t *ctx, aaa_stats_t *stats)
{
    if (ctx == NULL || stats == NULL) return AAA_ERR_NULL_PTR;

    stats->packets_processed  = ctx->packets_total;
    stats->packets_missed_eve = ctx->packets_missed_by_eve;

    /*
     * Equivocation formula for independent packets (Section II-A):
     *   ε_n = 1 - ∏(1 - μ_i)
     *
     * Approximated here assuming uniform miss probability:
     *   μ_avg = missed_by_eve / total_packets
     *   ε_n   = 1 - (1 - μ_avg)^n
     */
    if (ctx->packets_total > 0) {
        float mu_avg = (float)ctx->packets_missed_by_eve
                     / (float)ctx->packets_total;
        float product = 1.0f;
        for (uint32_t i = 0; i < ctx->packets_total; i++) {
            product *= (1.0f - mu_avg);
        }
        stats->equivocation = 1.0f - product;
        if (stats->equivocation > 1.0f) stats->equivocation = 1.0f;
    } else {
        stats->equivocation = 0.0f;
    }

    return AAA_OK;
}

bool aaa_is_secure(const aaa_ctx_t *ctx)
{
    if (ctx == NULL) return false;
    return ctx->perfect_secrecy_achieved;
}

void aaa_print_status(const aaa_ctx_t *ctx)
{
    if (ctx == NULL) {
        printf("[AAA] NULL context\n");
        return;
    }

    printf("[AAA] Key Engine Status\n");
    printf("[AAA]   Key (%d bytes): ", AAA_KEY_BYTES);
    for (int i = 0; i < AAA_KEY_BYTES; i++) {
        printf("%02X", ctx->key[i]);
        if ((i + 1) % 4 == 0 && i + 1 < AAA_KEY_BYTES) printf("_");
    }
    printf("\n");
    printf("[AAA]   Packets total     : %u\n", ctx->packets_total);
    printf("[AAA]   Eve missed packets: %u\n", ctx->packets_missed_by_eve);
    printf("[AAA]   Perfect secrecy   : %s\n",
           ctx->perfect_secrecy_achieved ? "YES ✓" : "NOT YET");

    aaa_stats_t stats;
    aaa_get_stats(ctx, &stats);
    printf("[AAA]   Equivocation ε_n  : %.4f  (1.0 = perfect)\n",
           stats.equivocation);
}
