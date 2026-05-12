// tb_key_accumulator.sv
//
// Drives a stream of "selected" 128-bit words into key_accumulator and
// checks the running XOR matches the C engine's key snapshot after
// each Bob-received round.

`timescale 1ns/1ps
`default_nettype none

module tb_key_accumulator;

    parameter int KEY_BYTES = 16;
    parameter int KEY_BITS  = KEY_BYTES * 8;

    logic                clk = 0;
    logic                rst_n = 0;
    logic                update = 0;
    logic                zeroize = 0;
    logic [KEY_BITS-1:0] selected_in = '0;
    wire  [KEY_BITS-1:0] key_out;

    key_accumulator #(.KEY_BYTES(KEY_BYTES)) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .update      (update),
        .zeroize     (zeroize),
        .selected_in (selected_in),
        .key_out     (key_out)
    );

    always #5 clk = ~clk;

    function automatic [KEY_BITS-1:0] load_hex_bytes(string path);
        logic [7:0] tmp [0:KEY_BYTES-1];
        logic [KEY_BITS-1:0] r;
        $readmemh(path, tmp);
        for (int i = 0; i < KEY_BYTES; i++) r[i*8 +: 8] = tmp[i];
        return r;
    endfunction

    int errors = 0;

    initial begin
        int fp, round, eve_rx, count = 0;
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        fp = $fopen("vectors/bob_rounds.txt", "r");
        if (fp == 0) begin
            $fatal(1, "Cannot open vectors/bob_rounds.txt — run tools/gen_rtl_vectors first.");
        end

        while ($fscanf(fp, "%d %d", round, eve_rx) == 2) begin
            string sel_path, key_path;
            logic [KEY_BITS-1:0] expected_key;
            sel_path = $sformatf("vectors/selected_%04d.hex", round);
            key_path = $sformatf("vectors/key_%04d.hex",      round);

            selected_in <= load_hex_bytes(sel_path);
            update      <= 1'b1;
            @(posedge clk);
            update      <= 1'b0;
            @(posedge clk);

            expected_key = load_hex_bytes(key_path);
            if (key_out !== expected_key) begin
                $error("Round %0d: key mismatch  got %h expected %h",
                       round, key_out, expected_key);
                errors++;
                if (errors > 5) break;
            end
            count++;
        end

        $fclose(fp);
        if (errors == 0) $display("[tb_key_accumulator] PASS: %0d rounds matched", count);
        else             $display("[tb_key_accumulator] FAIL: %0d errors over %0d rounds", errors, count);
        $finish;
    end

endmodule

`default_nettype wire
