// payload_buffer.sv
//
// Block 2: Payload Staging Buffer.
//
// Simple dual-port BRAM. The UART RX writes a packet byte-by-byte as
// it arrives. The bit_select_fold sequencer reads from it during the
// SELECT phase. Vivado infers a single 18 Kb BRAM (or distributed RAM
// for very small sizes) from the synchronous read pattern below.

`default_nettype none

module payload_buffer #(
    parameter int PAYLOAD_BYTES = 512,
    parameter int ADDR_W        = $clog2(PAYLOAD_BYTES)
) (
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire  [ADDR_W-1:0]    wr_addr,
    input  wire  [7:0]           wr_data,

    input  wire                  rd_en,
    input  wire  [ADDR_W-1:0]    rd_addr,
    output logic [7:0]           rd_data
);

    (* ram_style = "block" *) logic [7:0] mem [0:PAYLOAD_BYTES-1];

    always_ff @(posedge clk) begin
        if (wr_en) mem[wr_addr] <= wr_data;
        if (rd_en) rd_data      <= mem[rd_addr];
    end

endmodule

`default_nettype wire
