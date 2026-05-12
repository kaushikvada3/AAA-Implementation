// tb_bit_select_fold.sv
//
// End-to-end check of the bit-select / fold sequencer plus its PRNG
// and payload BRAM partners. For each Bob-received round we:
//   1. Pre-load payload_buffer with payload_<round>.hex.
//   2. Pulse `start` and wait for `done`.
//   3. Compare selected_out against selected_<round>.hex.
//
// PRNG state is NOT reset between rounds — it advances continuously,
// matching how the C engine treats ctx->prng_state across packets.

`timescale 1ns/1ps
`default_nettype none

module tb_bit_select_fold;

    parameter int KEY_BYTES     = 16;
    parameter int PAYLOAD_BYTES = 512;
    parameter int ADDR_W        = $clog2(PAYLOAD_BYTES);
    parameter int KEY_BITS      = KEY_BYTES * 8;

    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // PRNG
    logic        prng_advance;
    wire  [31:0] prng_rnd;
    xorshift32 #(.SEED_DEFAULT(32'hABCD_1234)) u_prng (
        .clk(clk), .rst_n(rst_n), .advance(prng_advance),
        .seed(32'hABCD_1234), .rnd_out(prng_rnd)
    );

    // BRAM
    logic              pb_wr_en;
    logic [ADDR_W-1:0] pb_wr_addr;
    logic [7:0]        pb_wr_data;
    logic              pb_rd_en;
    logic [ADDR_W-1:0] pb_rd_addr;
    wire  [7:0]        pb_rd_data;
    payload_buffer u_buf (
        .clk(clk),
        .wr_en(pb_wr_en), .wr_addr(pb_wr_addr), .wr_data(pb_wr_data),
        .rd_en(pb_rd_en), .rd_addr(pb_rd_addr), .rd_data(pb_rd_data)
    );

    // Fold sequencer
    logic                       start;
    wire                        busy, done;
    logic [KEY_BITS-1:0]        selected;
    wire                        selected_valid;
    wire  [ADDR_W-1:0]          fold_addr;
    wire                        fold_rd;

    bit_select_fold #(
        .KEY_BYTES     (KEY_BYTES),
        .PAYLOAD_BYTES (PAYLOAD_BYTES)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (start),
        .busy           (busy),
        .done           (done),
        .prng_advance   (prng_advance),
        .prng_rnd_out   (prng_rnd),
        .payload_addr   (fold_addr),
        .payload_rd     (fold_rd),
        .payload_data   (pb_rd_data),
        .selected_out   (selected),
        .selected_valid (selected_valid)
    );

    // BRAM port mux: writes from TB driver, reads from sequencer.
    logic [ADDR_W-1:0] tb_wr_addr;
    logic [7:0]        tb_wr_data;
    logic              tb_wr_en;
    always_comb begin
        pb_wr_en   = tb_wr_en;
        pb_wr_addr = tb_wr_addr;
        pb_wr_data = tb_wr_data;
        pb_rd_en   = fold_rd;
        pb_rd_addr = fold_addr;
    end

    // Load a payload into the BRAM
    task automatic load_payload(string path);
        logic [7:0] bytes [0:PAYLOAD_BYTES-1];
        $readmemh(path, bytes);
        for (int i = 0; i < PAYLOAD_BYTES; i++) begin
            @(posedge clk);
            tb_wr_en   <= 1'b1;
            tb_wr_addr <= i[ADDR_W-1:0];
            tb_wr_data <= bytes[i];
        end
        @(posedge clk);
        tb_wr_en <= 1'b0;
    endtask

    int errors = 0;
    int rounds_checked = 0;

    initial begin
        int fp, round, eve_rx;
        tb_wr_en = 0;
        start    = 0;
        rst_n    = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        fp = $fopen("vectors/bob_rounds.txt", "r");
        if (fp == 0) $fatal(1, "Open vectors/bob_rounds.txt failed");

        while ($fscanf(fp, "%d %d", round, eve_rx) == 2) begin
            string payload_path, expected_path;
            logic [7:0] expected_bytes [0:KEY_BYTES-1];
            logic [KEY_BITS-1:0] expected;

            payload_path  = $sformatf("vectors/payload_%04d.hex",  round);
            expected_path = $sformatf("vectors/selected_%04d.hex", round);

            load_payload(payload_path);

            @(posedge clk);
            start <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            // Wait for done
            while (!done) @(posedge clk);

            $readmemh(expected_path, expected_bytes);
            for (int i = 0; i < KEY_BYTES; i++) expected[i*8 +: 8] = expected_bytes[i];

            if (selected !== expected) begin
                $error("Round %0d: selected mismatch  got %h expected %h",
                       round, selected, expected);
                errors++;
                if (errors > 3) break;
            end
            rounds_checked++;
        end

        $fclose(fp);
        if (errors == 0) $display("[tb_bit_select_fold] PASS: %0d rounds matched", rounds_checked);
        else             $display("[tb_bit_select_fold] FAIL: %0d errors over %0d rounds", errors, rounds_checked);
        $finish;
    end

endmodule

`default_nettype wire
