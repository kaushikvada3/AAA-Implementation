// uart_tx.sv
//
// 8N1 UART transmitter. tx_ready is high while idle; assert tx_valid +
// tx_byte for one cycle to send a byte. Holds tx_ready low until the
// stop bit completes.

`default_nettype none

module uart_tx #(
    parameter int CLK_FREQ_HZ = 100_000_000,
    parameter int BAUD_RATE   =     115_200
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [7:0]  tx_byte,
    input  wire        tx_valid,
    output logic       tx_ready,

    output logic       tx            // serial line (idle high)
);

    localparam int BAUD_DIV = CLK_FREQ_HZ / BAUD_RATE;
    localparam int CNT_W    = $clog2(BAUD_DIV + 1);

    typedef enum logic [1:0] { S_IDLE, S_START, S_DATA, S_STOP } state_t;
    state_t state;

    logic [CNT_W-1:0] tick;
    logic [3:0]       bit_idx;
    logic [7:0]       shift;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            tick     <= '0;
            bit_idx  <= '0;
            shift    <= '0;
            tx_ready <= 1'b1;
            tx       <= 1'b1;
        end else begin
            unique case (state)
                S_IDLE: begin
                    tx       <= 1'b1;
                    tx_ready <= 1'b1;
                    if (tx_valid) begin
                        shift    <= tx_byte;
                        tx_ready <= 1'b0;
                        tick     <= '0;
                        bit_idx  <= '0;
                        state    <= S_START;
                    end
                end
                S_START: begin
                    tx <= 1'b0;
                    if (tick == BAUD_DIV[CNT_W-1:0] - 1) begin
                        tick  <= '0;
                        state <= S_DATA;
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end
                S_DATA: begin
                    tx <= shift[0];
                    if (tick == BAUD_DIV[CNT_W-1:0] - 1) begin
                        tick  <= '0;
                        shift <= {1'b1, shift[7:1]};
                        if (bit_idx == 4'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end
                S_STOP: begin
                    tx <= 1'b1;
                    if (tick == BAUD_DIV[CNT_W-1:0] - 1) begin
                        tick     <= '0;
                        tx_ready <= 1'b1;
                        state    <= S_IDLE;
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
