/**
 * aaa_key_engine.h
 * 
 * Hardware-portable implementation of the AAA (Accumulative, Adaptable,
 * Additive) Secret-Key Generation Method.
 * 
 * Based on: "A Remark on the AAA Method for Secret-Key Generation in
 * Mobile Networks" - Y. Hua, IEEE Wireless Commun. Letters, Dec. 2025.
 * 
 * Core principle:
 *   Kl,n = Xl,1 XOR Xl,2 XOR ... XOR Xl,n
 * 
 *   Where Xl,i is the lth bit selected from packet i's payload
 *   using a publicly agreed-upon protocol (PRNG seed).
 *   Security comes from Eve missing at least one packet.
 */

#ifndef AAA_KEY_ENGINE_H
#define AAA_KEY_ENGINE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* ── Configuration ─────────────────────────────────────────────────────────
 * Adjust these to match your system. Key sizes shown for reference:
 *   AAA_KEY_BYTES  16  →  128-bit key (AES-128)
 *   AAA_KEY_BYTES  32  →  256-bit key (AES-256)
 * -------------------------------------------------------------------------- */
#ifndef AAA_KEY_BYTES
#define AAA_KEY_BYTES       16          /* Default: 128-bit key              */
#endif

#ifndef AAA_MAX_PAYLOAD_BYTES
#define AAA_MAX_PAYLOAD_BYTES  2048     /* Max packet payload in bytes        */
#endif

/* ── Return Codes ──────────────────────────────────────────────────────────*/
typedef enum {
    AAA_OK              =  0,
    AAA_ERR_NULL_PTR    = -1,
    AAA_ERR_BAD_PAYLOAD = -2,
    AAA_ERR_NOT_READY   = -3,
    AAA_ERR_AUTH_FAIL   = -4,
} aaa_status_t;

/* ── Packet Loss Statistics ────────────────────────────────────────────────*/
typedef struct {
    uint32_t packets_processed;   /* Total packets fed to the engine         */
    uint32_t packets_missed_eve;  /* Estimated packets Eve missed (μ count)  */
    float    equivocation;        /* Current key equivocation [0.0 – 1.0]   */
                                  /*  = 1.0 means perfect secrecy            */
} aaa_stats_t;

/* ── Engine State ──────────────────────────────────────────────────────────
 * Keep one instance per key you want to maintain.
 * Zero-initialize before first use (or call aaa_init).
 * -------------------------------------------------------------------------- */
typedef struct {
    /* Current accumulated key */
    uint8_t  key[AAA_KEY_BYTES];

    /* PRNG state for the public bit-selection protocol.
     * Both users must seed this with the same public value. */
    uint32_t prng_state;

    /* Running packet counts */
    uint32_t packets_total;
    uint32_t packets_missed_by_eve;

    /* Set to true once at least one packet was missed by Eve */
    bool     perfect_secrecy_achieved;

    /* Internal scratch buffer */
    uint8_t  _selected[AAA_KEY_BYTES];
} aaa_ctx_t;

/* ── Public API ─────────────────────────────────────────────────────────── */

/**
 * aaa_init() - Initialize (or reset) an AAA engine context.
 *
 * @ctx          : Pointer to the context to initialize.
 * @public_seed  : A seed agreed upon publicly between both users.
 *                 This controls which bits are selected from each packet.
 *                 Both sides MUST use the same seed.
 */
aaa_status_t aaa_init(aaa_ctx_t *ctx, uint32_t public_seed);

/**
 * aaa_process_packet() - Feed a received/sent packet into the key engine.
 *
 * Call this every time a packet is successfully exchanged between
 * the two legitimate users (both sides call this on the same packet).
 *
 * @ctx             : Engine context.
 * @payload         : Pointer to packet payload (or its hash).
 * @payload_len     : Length of payload in bytes. Must be >= AAA_KEY_BYTES.
 * @eve_missed_this : Set true if you have reason to believe Eve missed
 *                    this packet (e.g., packet was on a faded sub-channel,
 *                    directional antenna, frequency hopped, etc.).
 *                    When unsure, use aaa_estimate_eve_miss().
 */
aaa_status_t aaa_process_packet(aaa_ctx_t   *ctx,
                                const uint8_t *payload,
                                size_t         payload_len,
                                bool           eve_missed_this);

/**
 * aaa_estimate_eve_miss() - Heuristic to estimate if Eve likely missed a packet.
 *
 * Uses a simple probabilistic model. If you have RSSI/SNR data or
 * directional info, implement your own logic instead.
 *
 * @snr_user_db  : SNR (dB) at the legitimate receiver.
 * @rate_bps     : Transmission rate in bits/sec.
 * @returns      : true if Eve is estimated to have missed the packet.
 */
bool aaa_estimate_eve_miss(float snr_user_db, uint32_t rate_bps);

/**
 * aaa_get_key() - Copy the current accumulated key into an output buffer.
 *
 * @ctx      : Engine context.
 * @out_key  : Output buffer. Must be at least AAA_KEY_BYTES long.
 */
aaa_status_t aaa_get_key(const aaa_ctx_t *ctx, uint8_t *out_key);

/**
 * aaa_get_stats() - Get current performance statistics.
 *
 * @ctx   : Engine context.
 * @stats : Output stats struct.
 */
aaa_status_t aaa_get_stats(const aaa_ctx_t *ctx, aaa_stats_t *stats);

/**
 * aaa_is_secure() - Returns true if perfect secrecy has been achieved.
 * 
 * This is true once at least one packet has been missed by Eve.
 * For asymptotic security, more misses are better.
 */
bool aaa_is_secure(const aaa_ctx_t *ctx);

/**
 * aaa_print_status() - Debug helper: print key and stats to stdout.
 * Remove or ifdef-out for production builds.
 */
void aaa_print_status(const aaa_ctx_t *ctx);

#endif /* AAA_KEY_ENGINE_H */
