// aaa_engine.sv
//
// Synthesis boundary for the AAA Secret-Key Generation Engine. Wires
// the six datapath blocks (xorshift32, payload_buffer, bit_select_fold,
// key_accumulator, secrecy_monitor, key_export) into one FSM that
// consumes a byte-stream input (rx_byte/rx_valid) and produces a
// byte-stream output (tx_byte/tx_valid/tx_ready).
//
// Wire protocol on the byte streams:
//   Input  per packet: [0xAA][eve_received_byte][PAYLOAD_BYTES payload]
//   Output per packet: [KEY_BYTES key bytes][status byte = {7'b0, key_secure}]
//
// This module deliberately excludes UART RX/TX so synthesis utilization
// and timing reports reflect only the AAA datapath. The UART instances
// live in aaa_engine_uart_wrap.sv (the bitstream's true top).

`default_nettype none

module aaa_engine #(
    parameter int          KEY_BYTES     = 16,
    parameter int          PAYLOAD_BYTES = 512,
    parameter logic [31:0] SEED          = 32'hABCD_1234
) (
    input  wire        clk,
    input  wire        rst_n,

    // Byte-stream input (from upstream UART RX or test driver)
    input  wire  [7:0] rx_byte,
    input  wire        rx_valid,

    // Byte-stream output (to downstream UART TX or test sink)
    output wire  [7:0] tx_byte,
    output wire        tx_valid,
    input  wire        tx_ready,

    // Status (drives LEDs / debug)
    output wire        key_secure,
    output wire [31:0] packets_total,
    output wire [31:0] packets_missed_by_eve,
    output wire [31:0] cumulative_secure_rounds,
    output wire [3:0]  fsm_state_dbg
);

    localparam int ADDR_W = $clog2(PAYLOAD_BYTES);

    // ───── FSM ────────────────────────────────────────────────────────
    typedef enum logic [3:0] {
        S_SYNC,
        S_RX_EVE,
        S_RX_PAYLOAD,
        S_FOLD,
        S_ACCUM,
        S_TX_KEY,
        S_TX_WAIT
    } state_t;

    state_t state, nxt;

    logic [ADDR_W:0] rx_cnt;
    logic            eve_flag;

    // ───── PRNG ───────────────────────────────────────────────────────
    logic         prng_advance;
    logic [31:0]  prng_rnd_out;

    xorshift32 #(.SEED_DEFAULT(SEED)) u_prng (
        .clk     (clk),
        .rst_n   (rst_n),
        .advance (prng_advance),
        .seed    (SEED),
        .rnd_out (prng_rnd_out)
    );

    // ───── Payload buffer (BRAM) ──────────────────────────────────────
    logic              pb_wr_en;
    logic [ADDR_W-1:0] pb_wr_addr;
    logic [7:0]        pb_wr_data;

    logic              pb_rd_en;
    logic [ADDR_W-1:0] pb_rd_addr;
    logic [7:0]        pb_rd_data;

    payload_buffer #(.PAYLOAD_BYTES(PAYLOAD_BYTES)) u_buf (
        .clk      (clk),
        .wr_en    (pb_wr_en),
        .wr_addr  (pb_wr_addr),
        .wr_data  (pb_wr_data),
        .rd_en    (pb_rd_en),
        .rd_addr  (pb_rd_addr),
        .rd_data  (pb_rd_data)
    );

    // ───── Bit-select / fold ──────────────────────────────────────────
    logic                       fold_start;
    logic                       fold_busy, fold_done;
    logic                       fold_prng_advance;
    logic [ADDR_W-1:0]          fold_pb_addr;
    logic                       fold_pb_rd;
    logic [KEY_BYTES*8-1:0]     fold_selected;
    logic                       fold_selected_valid;

    bit_select_fold #(
        .KEY_BYTES     (KEY_BYTES),
        .PAYLOAD_BYTES (PAYLOAD_BYTES)
    ) u_fold (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (fold_start),
        .busy           (fold_busy),
        .done           (fold_done),
        .prng_advance   (fold_prng_advance),
        .prng_rnd_out   (prng_rnd_out),
        .payload_addr   (fold_pb_addr),
        .payload_rd     (fold_pb_rd),
        .payload_data   (pb_rd_data),
        .selected_out   (fold_selected),
        .selected_valid (fold_selected_valid)
    );

    // ───── Key accumulator ────────────────────────────────────────────
    logic                       accum_update;
    logic                       accum_zeroize;
    logic [KEY_BYTES*8-1:0]     key_reg;

    key_accumulator #(.KEY_BYTES(KEY_BYTES)) u_accum (
        .clk         (clk),
        .rst_n       (rst_n),
        .update      (accum_update),
        .zeroize     (accum_zeroize),
        .selected_in (fold_selected),
        .key_out     (key_reg)
    );

    // ───── Secrecy monitor ────────────────────────────────────────────
    logic round_tick;
    secrecy_monitor u_mon (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .round_tick                (round_tick),
        .bob_received              (1'b1),  // implicit: we only process Bob's RX
        .eve_received              (eve_flag),
        .key_secure                (key_secure),
        .packets_total             (packets_total),
        .packets_missed_by_eve     (packets_missed_by_eve),
        .cumulative_secure_rounds  (cumulative_secure_rounds)
    );

    // ───── Key export (TX side) ───────────────────────────────────────
    logic export_start;
    logic export_busy, export_done;

    key_export #(.KEY_BYTES(KEY_BYTES)) u_export (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (export_start),
        .key_in     (key_reg),
        .key_secure (key_secure),
        .tx_byte    (tx_byte),
        .tx_valid   (tx_valid),
        .tx_ready   (tx_ready),
        .busy       (export_busy),
        .done       (export_done)
    );

    // ───── BRAM port arbitration ──────────────────────────────────────
    // Writes only during S_RX_PAYLOAD; reads only driven by fold.
    always_comb begin
        pb_wr_en   = (state == S_RX_PAYLOAD) && rx_valid;
        pb_wr_addr = rx_cnt[ADDR_W-1:0];
        pb_wr_data = rx_byte;
        pb_rd_en   = fold_pb_rd;
        pb_rd_addr = fold_pb_addr;
    end

    // ───── PRNG control multiplexing ──────────────────────────────────
    // Only the fold sequencer advances the PRNG during operation.
    assign prng_advance = fold_prng_advance;

    // ───── FSM transitions ────────────────────────────────────────────
    always_comb begin
        nxt           = state;
        fold_start    = 1'b0;
        accum_update  = 1'b0;
        round_tick    = 1'b0;
        export_start  = 1'b0;

        unique case (state)
            S_SYNC: begin
                if (rx_valid && rx_byte == 8'hAA) nxt = S_RX_EVE;
            end
            S_RX_EVE: begin
                if (rx_valid) nxt = S_RX_PAYLOAD;
            end
            S_RX_PAYLOAD: begin
                if (rx_valid && (rx_cnt == PAYLOAD_BYTES - 1)) nxt = S_FOLD;
            end
            S_FOLD: begin
                fold_start = 1'b1;     // sequencer self-arms on rising edge
                nxt = S_ACCUM;
            end
            S_ACCUM: begin
                if (fold_done) begin
                    accum_update = 1'b1;
                    round_tick   = 1'b1;
                    nxt          = S_TX_KEY;
                end
            end
            S_TX_KEY: begin
                export_start = 1'b1;
                nxt          = S_TX_WAIT;
            end
            S_TX_WAIT: begin
                if (export_done) nxt = S_SYNC;
            end
            default: nxt = S_SYNC;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_SYNC;
            rx_cnt    <= '0;
            eve_flag  <= 1'b0;
        end else begin
            state <= nxt;

            if (state == S_RX_EVE && rx_valid) begin
                eve_flag <= rx_byte[0];
            end

            if (state == S_RX_PAYLOAD && rx_valid) begin
                if (rx_cnt == PAYLOAD_BYTES - 1) rx_cnt <= '0;
                else                              rx_cnt <= rx_cnt + 1'b1;
            end else if (state == S_SYNC) begin
                rx_cnt <= '0;
            end
        end
    end

    assign accum_zeroize = 1'b0;     // exposed externally in future revision
    assign fsm_state_dbg = state;

endmodule

`default_nettype wire
