// xorshift32.sv
//
// Block 3 of the AAA engine: Public Selector PRNG.
//
// Bit-exact with prng_xorshift32() in aaa_key_engine.c. The C version
// chains three XOR-shift operations against the same scalar `x`. The
// faithful RTL form computes that chain combinationally and updates
// the state register on the rising edge when `advance` is asserted.
//
//   x ^= x << 13;
//   x ^= x >> 17;
//   x ^= x << 5;
//
// After reset, `state` holds the seed. The first `advance` pulse loads
// the first PRNG output. `rnd_out` reflects the current state value, so
// consumers should latch it on the cycle AFTER they assert `advance`.

`default_nettype none

module xorshift32 #(
    parameter logic [31:0] SEED_DEFAULT = 32'hABCD_1234
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        advance,
    input  wire [31:0] seed,           // sampled at rst_n
    output wire [31:0] rnd_out
);

    logic [31:0] state;
    logic [31:0] x0, x1, x2;

    always_comb begin
        x0 = state ^ (state << 13);
        x1 = x0    ^ (x0    >> 17);
        x2 = x1    ^ (x1    <<  5);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // C engine forbids zero seed (Xorshift32 would lock up).
            state <= (seed != 32'd0) ? seed : SEED_DEFAULT;
        end else if (advance) begin
            state <= x2;
        end
    end

    assign rnd_out = state;

endmodule

`default_nettype wire
