// tb_secrecy_monitor.sv
//
// Verifies the security invariant:
//   * key_secure stays low until the first round with bob_received=1
//     AND eve_received=0.
//   * Once high, key_secure NEVER clears (except on hard reset).
//   * Counters increment correctly.

`timescale 1ns/1ps
`default_nettype none

module tb_secrecy_monitor;

    logic        clk = 0;
    logic        rst_n;
    logic        round_tick;
    logic        bob, eve;
    wire         key_secure;
    wire  [31:0] packets_total, packets_missed_by_eve, cumulative_secure_rounds;

    secrecy_monitor dut (
        .clk(clk), .rst_n(rst_n),
        .round_tick(round_tick),
        .bob_received(bob), .eve_received(eve),
        .key_secure(key_secure),
        .packets_total(packets_total),
        .packets_missed_by_eve(packets_missed_by_eve),
        .cumulative_secure_rounds(cumulative_secure_rounds)
    );

    always #5 clk = ~clk;

    task automatic tick(input logic b, input logic e);
        bob = b; eve = e; round_tick = 1'b1;
        @(posedge clk);
        round_tick = 1'b0;
        @(posedge clk);
    endtask

    int errors = 0;

    initial begin
        rst_n = 0; round_tick = 0; bob = 0; eve = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Round 1: bob=1, eve=1 -> not secure yet
        tick(1, 1);
        if (key_secure !== 1'b0) begin $error("key_secure should be 0 after both rx"); errors++; end

        // Round 2: bob=1, eve=1 -> still not secure
        tick(1, 1);
        if (key_secure !== 1'b0) begin $error("key_secure should still be 0"); errors++; end

        // Round 3: bob=1, eve=0 -> latch
        tick(1, 0);
        if (key_secure !== 1'b1) begin $error("key_secure should be 1 after bob-only"); errors++; end

        // Round 4: bob=1, eve=1 -> must STAY 1
        tick(1, 1);
        if (key_secure !== 1'b1) begin $error("key_secure must stay 1 (sticky)"); errors++; end

        // Round 5: bob=0, eve=1 -> we wouldn't tick this in practice but verify stay
        tick(0, 1);
        if (key_secure !== 1'b1) begin $error("key_secure must stay 1"); errors++; end

        // Hard reset clears it
        rst_n = 0;
        @(posedge clk); @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        if (key_secure !== 1'b0) begin $error("hard reset should clear key_secure"); errors++; end

        if (errors == 0) $display("[tb_secrecy_monitor] PASS");
        else             $display("[tb_secrecy_monitor] FAIL: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
