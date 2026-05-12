// key_accumulator.sv
//
// Block 5: XOR Key Accumulator.
//
// One-cycle XOR of the selected word into the running key register.
// Parameterized for 128-bit (KEY_BYTES=16) or 256-bit (KEY_BYTES=32)
// synthesis variants. `zeroize` overrides and clears the key on the
// next clock — used by the key_export interface during teardown.

`default_nettype none

module key_accumulator #(
    parameter int KEY_BYTES = 16
) (
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       update,
    input  wire                       zeroize,
    input  wire [KEY_BYTES*8-1:0]     selected_in,
    output logic [KEY_BYTES*8-1:0]    key_out
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)         key_out <= '0;
        else if (zeroize)   key_out <= '0;
        else if (update)    key_out <= key_out ^ selected_in;
    end

endmodule

`default_nettype wire
