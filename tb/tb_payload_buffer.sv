// tb_payload_buffer.sv
//
// Smoke check of the BRAM-inferred payload buffer. Writes 512 bytes
// of a known pattern, reads them back, asserts equality. Verifies the
// synchronous read pattern (output appears on the cycle AFTER rd_en).

`timescale 1ns/1ps
`default_nettype none

module tb_payload_buffer;

    parameter int PAYLOAD_BYTES = 512;
    parameter int ADDR_W = $clog2(PAYLOAD_BYTES);

    logic              clk = 0;
    logic              wr_en;
    logic [ADDR_W-1:0] wr_addr;
    logic [7:0]        wr_data;
    logic              rd_en;
    logic [ADDR_W-1:0] rd_addr;
    wire  [7:0]        rd_data;

    payload_buffer dut (
        .clk(clk),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data)
    );

    always #5 clk = ~clk;

    int errors = 0;

    initial begin
        wr_en = 0; rd_en = 0; wr_addr = 0; wr_data = 0; rd_addr = 0;

        // Write phase
        @(posedge clk);
        for (int i = 0; i < PAYLOAD_BYTES; i++) begin
            wr_en   <= 1'b1;
            wr_addr <= i[ADDR_W-1:0];
            wr_data <= 8'(i ^ 8'hA5);
            @(posedge clk);
        end
        wr_en <= 1'b0;

        // Read phase (synchronous: data available on the next edge)
        for (int i = 0; i < PAYLOAD_BYTES; i++) begin
            rd_en   <= 1'b1;
            rd_addr <= i[ADDR_W-1:0];
            @(posedge clk);
            // data for i appears NOW (was registered last edge)
            if (i > 0) begin
                logic [7:0] expected = 8'((i - 1) & 32'hFF) ^ 8'hA5;
                if (rd_data !== expected) begin
                    $error("Read %0d: got %02h expected %02h", i-1, rd_data, expected);
                    errors++;
                end
            end
        end
        rd_en <= 1'b0;
        @(posedge clk);
        begin
            logic [7:0] expected_last = 8'((PAYLOAD_BYTES - 1) & 32'hFF) ^ 8'hA5;
            if (rd_data !== expected_last) begin
                $error("Final read: got %02h expected %02h", rd_data, expected_last);
                errors++;
            end
        end

        if (errors == 0) $display("[tb_payload_buffer] PASS");
        else             $display("[tb_payload_buffer] FAIL: %0d errors", errors);
        $finish;
    end

endmodule

`default_nettype wire
