// tb_key_export.sv
//
// Drives a known 128-bit key into the export module, drains 17 bytes
// from the byte-stream output (16 key bytes + 1 status byte), and
// verifies the order and trailing status byte.

`timescale 1ns/1ps
`default_nettype none

module tb_key_export;

    parameter int KEY_BYTES = 16;
    parameter int KEY_BITS  = KEY_BYTES * 8;

    logic                 clk = 0, rst_n;
    logic                 start;
    logic [KEY_BITS-1:0]  key_in;
    logic                 key_secure;
    wire  [7:0]           tx_byte;
    wire                  tx_valid, busy, done;
    logic                 tx_ready;

    key_export #(.KEY_BYTES(KEY_BYTES)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .key_in(key_in), .key_secure(key_secure),
        .tx_byte(tx_byte), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .busy(busy), .done(done)
    );

    always #5 clk = ~clk;

    int errors = 0;
    logic [7:0] received [0:KEY_BYTES];   // 16 key + 1 status

    initial begin
        tx_ready = 1;
        start = 0;
        key_secure = 1;
        // Recognizable pattern: byte i = i ^ 0x3C
        for (int i = 0; i < KEY_BYTES; i++) key_in[i*8 +: 8] = i ^ 8'h3C;

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        // Sample whenever tx_valid && tx_ready (one byte per clock here
        // because tx_ready is held high). Collect until done.
        begin
            int idx = 0;
            while (!done) begin
                @(posedge clk);
                if (tx_valid) begin
                    received[idx] = tx_byte;
                    idx++;
                end
            end
            if (idx !== KEY_BYTES + 1) begin
                $error("Expected %0d bytes drained, got %0d", KEY_BYTES + 1, idx);
                errors++;
            end
        end

        for (int i = 0; i < KEY_BYTES; i++) begin
            if (received[i] !== (i ^ 8'h3C)) begin
                $error("Key byte %0d: got %02h expected %02h", i, received[i], i ^ 8'h3C);
                errors++;
            end
        end
        if (received[KEY_BYTES] !== 8'h01) begin
            $error("Status byte: got %02h expected %02h", received[KEY_BYTES], 8'h01);
            errors++;
        end

        if (errors == 0) $display("[tb_key_export] PASS");
        else             $display("[tb_key_export] FAIL: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
