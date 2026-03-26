/**
 * aaa_demo.c
 *
 * Demonstrates and tests the AAA Key Engine.
 * Simulates two users (Alice and Bob) exchanging packets and
 * an eavesdropper (Eve) who misses some of them.
 *
 * Compile:
 *   gcc -O2 -Wall -o aaa_demo aaa_demo.c aaa_key_engine.c -lm
 *
 * For embedded targets (e.g., STM32, ESP32):
 *   Simply add aaa_key_engine.h + aaa_key_engine.c to your project.
 *   Replace the demo loop with calls from your radio receive callback.
 */

#include "aaa_key_engine.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ── Simulate a packet payload ─────────────────────────────────────────── */
static void simulate_packet(uint8_t *payload, size_t len, uint32_t packet_num)
{
    /* In a real system this is the actual packet payload from your radio.
     * Here we just fill it with pseudo-random data to simulate real traffic. */
    srand(packet_num * 1337 + 42);
    for (size_t i = 0; i < len; i++) {
        payload[i] = (uint8_t)(rand() & 0xFF);
    }
}

/* ── Scenario 1: Basic Key Agreement ───────────────────────────────────── */
static void demo_basic_agreement(void)
{
    printf("══════════════════════════════════════════════════════\n");
    printf("  SCENARIO 1: Basic Key Agreement (Alice ↔ Bob)\n");
    printf("══════════════════════════════════════════════════════\n\n");

    aaa_ctx_t alice_ctx, bob_ctx;

    /* Both sides init with the SAME public seed — this is the "public protocol"
     * referenced in the paper. Can be a session ID, timestamp, nonce, etc. */
    uint32_t public_seed = 0xABCD1234u;
    aaa_init(&alice_ctx, public_seed);
    aaa_init(&bob_ctx,   public_seed);

    uint8_t payload[256];
    uint8_t alice_key[AAA_KEY_BYTES];
    uint8_t bob_key[AAA_KEY_BYTES];

    int num_packets    = 20;
    int eve_miss_every = 3;  /* Eve misses 1 in every N packets */

    printf("Processing %d packets (Eve misses every %d)...\n\n",
           num_packets, eve_miss_every);

    for (int i = 1; i <= num_packets; i++) {
        simulate_packet(payload, sizeof(payload), (uint32_t)i);

        /* Eve misses this packet? */
        bool eve_missed = (i % eve_miss_every == 0);

        /* Both Alice and Bob process the same packet identically */
        aaa_process_packet(&alice_ctx, payload, sizeof(payload), eve_missed);
        aaa_process_packet(&bob_ctx,   payload, sizeof(payload), eve_missed);

        if (i <= 5 || i == num_packets) {
            printf("  Packet %2d | Eve missed: %s | Secure: %s\n",
                   i,
                   eve_missed ? "YES" : "no ",
                   aaa_is_secure(&alice_ctx) ? "YES" : "not yet");
        } else if (i == 6) {
            printf("  ...\n");
        }
    }

    printf("\n");
    aaa_print_status(&alice_ctx);

    /* Verify Alice and Bob derived the same key */
    aaa_get_key(&alice_ctx, alice_key);
    aaa_get_key(&bob_ctx,   bob_key);

    bool keys_match = (memcmp(alice_key, bob_key, AAA_KEY_BYTES) == 0);
    printf("\n[RESULT] Alice's key == Bob's key: %s\n\n",
           keys_match ? "✓ MATCH" : "✗ MISMATCH (BUG!)");
}

/* ── Scenario 2: Correlated Packets (Markov Model, Section II-B) ────────── */
static void demo_correlated_packets(void)
{
    printf("══════════════════════════════════════════════════════\n");
    printf("  SCENARIO 2: Correlated Packets (Markov, α=0.3)\n");
    printf("══════════════════════════════════════════════════════\n\n");
    printf("  Paper Theorem 1: even with packet correlation,\n");
    printf("  equivocation → 1.0 as n → ∞ if Eve misses any packet.\n\n");

    aaa_ctx_t ctx;
    aaa_init(&ctx, 0xCAFEBABEu);

    uint8_t payload[512];
    uint8_t prev_payload[512];
    float   alpha = 0.3f;    /* Correlation: Markov parameter from paper */
    float   mu    = 0.15f;   /* Eve's miss probability per packet         */

    srand(999);
    simulate_packet(prev_payload, sizeof(prev_payload), 0);

    printf("  %-8s %-10s %-12s %-12s\n",
           "Packet", "Correlated", "Eve Missed", "Equivocation");
    printf("  %-8s %-10s %-12s %-12s\n",
           "------", "----------", "----------", "------------");

    for (int i = 1; i <= 50; i++) {
        /* Simulate correlated payload: blend with previous packet */
        simulate_packet(payload, sizeof(payload), (uint32_t)i);
        for (size_t b = 0; b < sizeof(payload); b++) {
            if ((float)rand() / RAND_MAX < alpha) {
                payload[b] = prev_payload[b];  /* correlated bit */
            }
        }
        memcpy(prev_payload, payload, sizeof(payload));

        /* Eve misses with probability mu */
        bool eve_missed = ((float)rand() / RAND_MAX < mu);

        aaa_process_packet(&ctx, payload, sizeof(payload), eve_missed);

        /* Print snapshots at key points */
        if (i == 1 || i == 5 || i == 10 || i == 20 || i == 50) {
            aaa_stats_t stats;
            aaa_get_stats(&ctx, &stats);
            printf("  %-8d %-10s %-12s %.6f\n",
                   i,
                   "YES (α=0.3)",
                   eve_missed ? "YES" : "no",
                   stats.equivocation);
        }
    }

    printf("\n");
    aaa_print_status(&ctx);
    printf("\n");
}

/* ── Scenario 3: Platform Integration Template ───────────────────────────
 * This shows how you'd wire the AAA engine into a real radio callback.
 * Replace the stub functions with your actual radio driver calls.
 * ─────────────────────────────────────────────────────────────────────── */

/* --- Stub types (replace with your radio driver's actual types) --- */
typedef struct {
    uint8_t  data[256];
    uint16_t length;
    int8_t   rssi_dbm;       /* Received Signal Strength Indicator */
    uint8_t  snr_db;         /* Signal-to-Noise Ratio              */
    bool     crc_ok;         /* CRC / authentication passed        */
} radio_packet_t;

/* Global engine instance — one per key you're managing */
static aaa_ctx_t g_key_engine;
static bool      g_engine_initialized = false;

/**
 * aaa_radio_init() — Call once at startup, after your radio is ready.
 * 
 * @session_id: A shared session identifier. Both nodes MUST agree on this.
 *              Could be a pre-shared nonce, a timestamp rounded to the hour,
 *              or a value exchanged in a handshake (e.g., LoRaWAN DevNonce).
 */
void aaa_radio_init(uint32_t session_id)
{
    aaa_init(&g_key_engine, session_id);
    g_engine_initialized = true;
    printf("[AAA] Engine initialized. Session ID: 0x%08X\n", session_id);
}

/**
 * aaa_on_packet_received() — Wire this into your radio RX interrupt or
 * packet receive callback.
 *
 * For example:
 *   WiFi  (ESP-IDF): call from esp_wifi_set_promiscuous_rx_cb handler
 *   LoRa  (Arduino): call from onReceive() in RadioLib/LoRa library
 *   ZigBee (Zephyr): call from ieee802154_radio_api.rx() handler
 */
void aaa_on_packet_received(const radio_packet_t *pkt)
{
    if (!g_engine_initialized || pkt == NULL) return;
    if (!pkt->crc_ok)                          return;  /* Reject bad packets */

    /* Estimate if Eve likely missed this packet based on link quality */
    bool eve_missed = aaa_estimate_eve_miss((float)pkt->snr_db, 250000);

    /* Feed packet into the key engine */
    aaa_status_t status = aaa_process_packet(&g_key_engine,
                                              pkt->data,
                                              pkt->length,
                                              eve_missed);

    if (status != AAA_OK) {
        printf("[AAA] Warning: packet processing failed (%d)\n", status);
        return;
    }

    /* Optionally print when key becomes secure */
    if (aaa_is_secure(&g_key_engine)) {
        aaa_stats_t stats;
        aaa_get_stats(&g_key_engine, &stats);
        /* Uncomment for live debugging: */
        /* aaa_print_status(&g_key_engine); */
        (void)stats;
    }
}

/**
 * aaa_get_current_key() — Call this whenever you need the latest key,
 * e.g., before encrypting a message or refreshing an AES session key.
 *
 * Returns false if the key is not yet secure (Eve hasn't missed any packet).
 */
bool aaa_get_current_key(uint8_t out_key[AAA_KEY_BYTES])
{
    if (!aaa_is_secure(&g_key_engine)) {
        printf("[AAA] Warning: key not yet secure. Wait for Eve to miss a packet.\n");
        return false;
    }
    aaa_get_key(&g_key_engine, out_key);
    return true;
}

static void demo_integration_template(void)
{
    printf("══════════════════════════════════════════════════════\n");
    printf("  SCENARIO 3: Radio Integration Template\n");
    printf("══════════════════════════════════════════════════════\n\n");

    /* Simulate startup */
    aaa_radio_init(0x1A2B3C4Du);

    /* Simulate receiving 10 packets from the radio */
    for (int i = 0; i < 10; i++) {
        radio_packet_t pkt;
        simulate_packet(pkt.data, 200, (uint32_t)i);
        pkt.length   = 200;
        pkt.rssi_dbm = -60 + (i * 2);
        pkt.snr_db   = 10 + (i % 5);
        pkt.crc_ok   = true;

        aaa_on_packet_received(&pkt);
    }

    /* Retrieve the key for use */
    uint8_t session_key[AAA_KEY_BYTES];
    if (aaa_get_current_key(session_key)) {
        printf("[APP]  Session key ready: ");
        for (int i = 0; i < AAA_KEY_BYTES; i++) printf("%02X", session_key[i]);
        printf("\n[APP]  → Pass this to AES, ChaCha20, or your cipher of choice.\n");
    }
    printf("\n");
}

/* ── Main ───────────────────────────────────────────────────────────────── */
int main(void)
{
    printf("\n");
    printf("╔══════════════════════════════════════════════════════╗\n");
    printf("║    AAA Secret-Key Generation Engine — Demo          ║\n");
    printf("║    Key size: %3d bytes (%d bits)                    ║\n",
           AAA_KEY_BYTES, AAA_KEY_BYTES * 8);
    printf("╚══════════════════════════════════════════════════════╝\n\n");

    demo_basic_agreement();
    demo_correlated_packets();
    demo_integration_template();

    return 0;
}
