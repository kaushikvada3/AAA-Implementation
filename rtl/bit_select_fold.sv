// bit_select_fold.sv
//
// Block 4: Bit-Select & Fold Network.
//
// Mirrors select_bits_from_payload() in aaa_key_engine.c. For each of
// KEY_BYTES output bytes the C engine does:
//
//   r1 = prng(); idx1 = r1 % payload_len;
//   r2 = prng(); idx2 = r2 % payload_len;
//   selected[l] = payload[idx1] ^ payload[idx2];
//
// This RTL form keeps the same PRNG call order so byte-stream output
// matches the C engine exactly. PAYLOAD_BYTES is fixed at 512 — modulo
// reduces to addr = rnd[8:0], no divider needed.
//
// Pipeline per byte (4 cycles):
//   t+0  drive advance  -> PRNG state updates on next edge
//   t+1  rnd_out = r1   -> capture r1, request payload[r1[8:0]], advance again
//   t+2  rnd_out = r2   -> capture r2, request payload[r2[8:0]], stash byte_a
//   t+3  store selected -> selected[byte_idx] <= byte_a ^ byte_b, next byte_idx
//
// Total: 4 * KEY_BYTES cycles after `start`. For KEY_BYTES=16 that is
// 64 cycles ~= 640 ns @ 100 MHz. `done` pulses for one cycle when the
// full selected[] vector is ready.

`default_nettype none

module bit_select_fold #(
    parameter int KEY_BYTES     = 16,
    parameter int PAYLOAD_BYTES = 512,
    parameter int PAYLOAD_ADDR_W = $clog2(PAYLOAD_BYTES)
) (
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          start,
    output logic                         busy,
    output logic                         done,

    // PRNG control / data
    output logic                         prng_advance,
    input  wire  [31:0]                  prng_rnd_out,

    // BRAM read port
    output logic [PAYLOAD_ADDR_W-1:0]    payload_addr,
    output logic                         payload_rd,
    input  wire  [7:0]                   payload_data,

    // Selected output
    output logic [KEY_BYTES*8-1:0]       selected_out,
    output logic                         selected_valid
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_ADV1,    // assert prng_advance for r1
        S_READ1,   // r1 available, issue BRAM read for byte_a, advance for r2
        S_READ2,   // r2 available, issue BRAM read for byte_b, capture byte_a
        S_XOR,     // byte_b available, write selected[byte_idx]
        S_DONE
    } state_t;

    state_t state, nxt;

    localparam int IDX_W = $clog2(KEY_BYTES);

    logic [IDX_W:0]                 byte_idx;     // 0..KEY_BYTES
    logic [7:0]                     byte_a;
    logic [KEY_BYTES*8-1:0]         selected_r;

    // ───── Next-state ─────────────────────────────────────────────────
    always_comb begin
        nxt = state;
        unique case (state)
            S_IDLE:   if (start)                nxt = S_ADV1;
            S_ADV1:                              nxt = S_READ1;
            S_READ1:                             nxt = S_READ2;
            S_READ2:                             nxt = S_XOR;
            S_XOR: begin
                if (byte_idx == KEY_BYTES[IDX_W:0] - 1)
                    nxt = S_DONE;
                else
                    nxt = S_ADV1;
            end
            S_DONE:                              nxt = S_IDLE;
            default:                             nxt = S_IDLE;
        endcase
    end

    // ───── Datapath ───────────────────────────────────────────────────
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state           <= S_IDLE;
            byte_idx        <= '0;
            byte_a          <= '0;
            selected_r      <= '0;
            selected_valid  <= 1'b0;
        end else begin
            state <= nxt;

            // Defaults
            selected_valid <= 1'b0;

            unique case (state)
                S_IDLE: begin
                    byte_idx <= '0;
                    if (start) selected_r <= '0;
                end
                // S_ADV1: prng_advance high (see comb). Next cycle rnd_out = r1.
                S_READ2: begin
                    // pb_rd_data = payload[r1[8:0]] is available this cycle.
                    byte_a  <= payload_data;
                end
                S_XOR: begin
                    // pb_rd_data = payload[r2[8:0]] is available this cycle.
                    selected_r[byte_idx*8 +: 8] <= byte_a ^ payload_data;
                    byte_idx <= byte_idx + 1'b1;
                end
                S_DONE: begin
                    selected_valid <= 1'b1;
                end
                default: ;
            endcase
        end
    end

    // ───── Combinational control outputs ──────────────────────────────
    always_comb begin
        prng_advance = 1'b0;
        payload_rd   = 1'b0;
        payload_addr = '0;
        busy         = (state != S_IDLE) && (state != S_DONE);
        done         = (state == S_DONE);

        unique case (state)
            S_ADV1: begin
                prng_advance = 1'b1;     // capture r1 next cycle
            end
            S_READ1: begin
                payload_addr = prng_rnd_out[PAYLOAD_ADDR_W-1:0];
                payload_rd   = 1'b1;
                prng_advance = 1'b1;     // capture r2 next cycle
            end
            S_READ2: begin
                payload_addr = prng_rnd_out[PAYLOAD_ADDR_W-1:0];
                payload_rd   = 1'b1;
            end
            default: ;
        endcase
    end

    assign selected_out = selected_r;

endmodule

`default_nettype wire
