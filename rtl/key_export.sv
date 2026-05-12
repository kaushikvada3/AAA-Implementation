// key_export.sv
//
// Block 7: Key Export & Crypto Interface.
//
// Drains the running key register byte-by-byte to a downstream byte
// channel (used by the UART TX). Asserting `start` initiates a burst
// of KEY_BYTES bytes plus a trailing status byte ({7'b0, key_secure})
// to indicate whether the key has reached the "secure" state.
//
// A separate `zeroize_req` output is asserted on demand by the host;
// it is consumed by key_accumulator to clear the key register.

`default_nettype none

module key_export #(
    parameter int KEY_BYTES = 16
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       start,
    input  wire  [KEY_BYTES*8-1:0]    key_in,
    input  wire                       key_secure,

    // Downstream byte channel (UART TX)
    output logic [7:0]                tx_byte,
    output logic                      tx_valid,
    input  wire                       tx_ready,
    output logic                      busy,
    output logic                      done
);

    localparam int CNT_W = $clog2(KEY_BYTES + 1) + 1;
    localparam logic [CNT_W-1:0] LAST_IDX = KEY_BYTES[CNT_W-1:0]; // status byte

    typedef enum logic [1:0] { S_IDLE, S_SEND, S_STATUS, S_DONE } state_t;
    state_t state;

    logic [CNT_W-1:0] idx;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            idx   <= '0;
        end else begin
            unique case (state)
                S_IDLE: begin
                    idx <= '0;
                    if (start) state <= S_SEND;
                end
                S_SEND: begin
                    if (tx_ready && tx_valid) begin
                        if (idx == KEY_BYTES[CNT_W-1:0] - 1) begin
                            state <= S_STATUS;
                            idx   <= idx + 1'b1;
                        end else begin
                            idx <= idx + 1'b1;
                        end
                    end
                end
                S_STATUS: begin
                    if (tx_ready && tx_valid) state <= S_DONE;
                end
                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

    always_comb begin
        tx_valid = 1'b0;
        tx_byte  = 8'h00;
        busy     = (state != S_IDLE);
        done     = (state == S_DONE);
        unique case (state)
            S_SEND: begin
                tx_valid = 1'b1;
                tx_byte  = key_in[idx*8 +: 8];
            end
            S_STATUS: begin
                tx_valid = 1'b1;
                tx_byte  = {7'b0, key_secure};
            end
            default: ;
        endcase
    end

endmodule

`default_nettype wire
