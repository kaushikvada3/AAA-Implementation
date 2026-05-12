// uart_rx.sv
//
// 8N1 UART receiver. CLK_FREQ_HZ must match the system clock; BAUD_RATE
// is whatever the host is configured for (115200 by default).
//
// Output protocol:
//   rx_valid pulses high for one clk cycle when rx_byte is valid.

`default_nettype none

module uart_rx #(
    parameter int CLK_FREQ_HZ = 100_000_000,
    parameter int BAUD_RATE   =     115_200
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx,           // serial line from host (idle high)
    output logic [7:0] rx_byte,
    output logic       rx_valid
);

    localparam int BAUD_DIV  = CLK_FREQ_HZ / BAUD_RATE;          // 868
    localparam int HALF_DIV  = BAUD_DIV / 2;                     // 434
    localparam int CNT_W     = $clog2(BAUD_DIV + 1);

    typedef enum logic [2:0] { S_IDLE, S_START, S_DATA, S_STOP, S_DONE } state_t;
    state_t state;

    logic [CNT_W-1:0] tick;
    logic [2:0]       bit_idx;
    logic [7:0]       shift;
    logic             rx_sync_1, rx_sync_0; // 2-FF synchronizer

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync_1 <= 1'b1;
            rx_sync_0 <= 1'b1;
        end else begin
            rx_sync_1 <= rx;
            rx_sync_0 <= rx_sync_1;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            tick     <= '0;
            bit_idx  <= '0;
            shift    <= '0;
            rx_byte  <= '0;
            rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            unique case (state)
                S_IDLE: begin
                    tick    <= '0;
                    bit_idx <= '0;
                    if (rx_sync_0 == 1'b0) state <= S_START;
                end
                S_START: begin
                    if (tick == HALF_DIV[CNT_W-1:0] - 1) begin
                        if (rx_sync_0 == 1'b0) begin // valid start bit
                            state <= S_DATA;
                            tick  <= '0;
                        end else begin
                            state <= S_IDLE;          // glitch
                        end
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end
                S_DATA: begin
                    if (tick == BAUD_DIV[CNT_W-1:0] - 1) begin
                        tick               <= '0;
                        shift              <= {rx_sync_0, shift[7:1]};  // LSB first
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end
                S_STOP: begin
                    if (tick == BAUD_DIV[CNT_W-1:0] - 1) begin
                        tick     <= '0;
                        rx_byte  <= shift;
                        rx_valid <= 1'b1;
                        state    <= S_DONE;
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end
                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
