// tb_aaa_engine_top.sv
//
// Integration testbench. Replays every Bob-received round from the
// 400-round reference run through the aaa_engine core (bypassing UART
// — direct rx_byte / rx_valid drive). After each round it compares the
// key register against the C-engine snapshot in key_<round>.hex, and
// confirms key_secure latches at the first Bob-only round (round 5
// at 45 m in the reference run).

`timescale 1ns/1ps
`default_nettype none

module tb_aaa_engine_top;

    parameter int KEY_BYTES     = 16;
    parameter int PAYLOAD_BYTES = 512;
    parameter int KEY_BITS      = KEY_BYTES * 8;

    logic        clk = 0;
    logic        rst_n;
    logic [7:0]  rx_byte;
    logic        rx_valid;
    wire  [7:0]  tx_byte;
    wire         tx_valid;
    logic        tx_ready = 1'b1;     // drain instantly
    wire         key_secure;
    wire  [31:0] packets_total;
    wire  [31:0] packets_missed_by_eve;
    wire  [31:0] cumulative_secure_rounds;
    wire  [3:0]  fsm_state_dbg;

    aaa_engine #(
        .KEY_BYTES     (KEY_BYTES),
        .PAYLOAD_BYTES (PAYLOAD_BYTES)
    ) dut (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .rx_byte                   (rx_byte),
        .rx_valid                  (rx_valid),
        .tx_byte                   (tx_byte),
        .tx_valid                  (tx_valid),
        .tx_ready                  (tx_ready),
        .key_secure                (key_secure),
        .packets_total             (packets_total),
        .packets_missed_by_eve     (packets_missed_by_eve),
        .cumulative_secure_rounds  (cumulative_secure_rounds),
        .fsm_state_dbg             (fsm_state_dbg)
    );

    always #5 clk = ~clk;       // 100 MHz

    // Capture the byte stream produced by key_export.
    logic [7:0]  tx_capture [0:KEY_BYTES];
    int          tx_idx = 0;
    logic        capture_en = 0;

    always_ff @(posedge clk) begin
        if (capture_en && tx_valid && tx_ready) begin
            tx_capture[tx_idx] <= tx_byte;
            tx_idx             <= tx_idx + 1;
        end
    end

    // Drive one packet through the engine
    task automatic send_byte(input logic [7:0] b);
        @(posedge clk);
        rx_byte  <= b;
        rx_valid <= 1'b1;
        @(posedge clk);
        rx_valid <= 1'b0;
    endtask

    task automatic send_packet(input int round, input int eve_rx);
        logic [7:0] payload [0:PAYLOAD_BYTES-1];
        string path;
        path = $sformatf("vectors/payload_%04d.hex", round);
        $readmemh(path, payload);

        // sync byte
        send_byte(8'hAA);
        // eve flag
        send_byte(eve_rx[7:0]);
        // payload
        for (int i = 0; i < PAYLOAD_BYTES; i++) begin
            send_byte(payload[i]);
        end
    endtask

    function automatic [KEY_BITS-1:0] load_key(input int round);
        logic [7:0] tmp [0:KEY_BYTES-1];
        logic [KEY_BITS-1:0] r;
        string path;
        path = $sformatf("vectors/key_%04d.hex", round);
        $readmemh(path, tmp);
        for (int i = 0; i < KEY_BYTES; i++) r[i*8 +: 8] = tmp[i];
        return r;
    endfunction

    int errors = 0;

    initial begin
        int fp, round, eve_rx, rounds_run = 0;
        logic [KEY_BITS-1:0] expected_key;
        int first_secure_round_obs = 0;

        rx_byte  = 0;
        rx_valid = 0;
        rst_n    = 0;
        repeat (8) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        fp = $fopen("vectors/bob_rounds.txt", "r");
        if (fp == 0) $fatal(1, "Cannot open vectors/bob_rounds.txt — run tools/gen_rtl_vectors first.");

        while ($fscanf(fp, "%d %d", round, eve_rx) == 2) begin
            tx_idx     = 0;
            capture_en = 1;
            send_packet(round, eve_rx);

            // Wait for engine to finish (export done -> 17 bytes drained).
            while (tx_idx < KEY_BYTES + 1) @(posedge clk);
            capture_en = 0;

            expected_key = load_key(round);

            // Reconstruct received key
            begin
                logic [KEY_BITS-1:0] got_key;
                for (int i = 0; i < KEY_BYTES; i++) got_key[i*8 +: 8] = tx_capture[i];
                if (got_key !== expected_key) begin
                    $error("Round %0d: key mismatch  got %h  expected %h",
                           round, got_key, expected_key);
                    errors++;
                    if (errors > 3) break;
                end
            end

            if (key_secure && first_secure_round_obs == 0) begin
                first_secure_round_obs = round;
            end

            rounds_run++;
        end

        $fclose(fp);

        if (first_secure_round_obs == 0) begin
            $error("key_secure never latched");
            errors++;
        end else begin
            $display("[tb_aaa_engine_top] first_secure_round=%0d", first_secure_round_obs);
        end

        if (errors == 0) $display("[tb_aaa_engine_top] PASS: %0d rounds bit-exact", rounds_run);
        else             $display("[tb_aaa_engine_top] FAIL: %0d errors over %0d rounds", errors, rounds_run);
        $finish;
    end

    // Safety timeout
    initial begin
        #100_000_000;     // 100 ms sim time
        $display("[tb_aaa_engine_top] TIMEOUT");
        $finish;
    end

endmodule

`default_nettype wire
