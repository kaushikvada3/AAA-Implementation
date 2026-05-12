// tb_xorshift32.sv
//
// Compares the SystemVerilog PRNG output against the C reference. The
// vector generator emits prng_<round>.hex with the first 32 PRNG values
// produced after seeding with PUBLIC_SEED. This TB reads round 0003
// (first Bob-received round) and walks both halves of the PRNG advance
// pattern that bit_select_fold will issue at runtime.

`timescale 1ns/1ps
`default_nettype none

module tb_xorshift32;

    logic        clk = 0;
    logic        rst_n = 0;
    logic        advance = 0;
    logic [31:0] seed = 32'hABCD_1234;
    wire  [31:0] rnd_out;

    xorshift32 dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .advance (advance),
        .seed    (seed),
        .rnd_out (rnd_out)
    );

    always #5 clk = ~clk;   // 100 MHz

    localparam int N_EXPECTED = 32;
    logic [31:0] expected [0:N_EXPECTED-1];
    int errors = 0;

    initial begin
        $readmemh("vectors/prng_0003.hex", expected);

        // Apply reset
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        for (int i = 0; i < N_EXPECTED; i++) begin
            advance <= 1'b1;
            @(posedge clk);
            advance <= 1'b0;
            @(posedge clk);
            // After advance + one edge, rnd_out reflects the new state.
            if (rnd_out !== expected[i]) begin
                $error("PRNG[%0d] got %08h expected %08h", i, rnd_out, expected[i]);
                errors++;
            end
        end

        if (errors == 0) $display("[tb_xorshift32] PASS: %0d outputs matched", N_EXPECTED);
        else             $display("[tb_xorshift32] FAIL: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
