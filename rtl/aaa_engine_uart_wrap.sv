// aaa_engine_uart_wrap.sv
//
// Bitstream top-level. Wraps aaa_engine with a UART RX and TX so the
// Arty A7-100T's USB-UART bridge can drive HIL test packets from the
// host PC. LEDs reflect key_secure and the lower 3 bits of the FSM
// debug state.
//
// This is the module synthesized into the .bit file. The synthesis
// reports cited in the paper are produced by re-running synthesis on
// `aaa_engine` directly (no UART).

`default_nettype none

module aaa_engine_uart_wrap #(
    parameter int          CLK_FREQ_HZ = 100_000_000,
    parameter int          BAUD_RATE   =     115_200,
    parameter int          KEY_BYTES   = 16,
    parameter logic [31:0] SEED        = 32'hABCD_1234
) (
    input  wire       CLK100MHZ,
    input  wire       ck_rst_n,      // active-low push-button reset (CK_RST)

    input  wire       uart_rxd_out,  // FPGA RX  (host -> FPGA)
    output wire       uart_txd_in,   // FPGA TX  (FPGA -> host)

    output wire [3:0] led            // [0]=key_secure, [3:1]=fsm_state_dbg[2:0]
);

    // ───── Reset synchronizer ─────────────────────────────────────────
    logic [3:0] rst_sync;
    wire        rst_n;

    always_ff @(posedge CLK100MHZ or negedge ck_rst_n) begin
        if (!ck_rst_n) rst_sync <= 4'b0000;
        else           rst_sync <= {rst_sync[2:0], 1'b1};
    end
    assign rst_n = rst_sync[3];

    // ───── UART RX ────────────────────────────────────────────────────
    logic [7:0] rx_byte;
    logic       rx_valid;

    uart_rx #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)) u_uart_rx (
        .clk      (CLK100MHZ),
        .rst_n    (rst_n),
        .rx       (uart_rxd_out),
        .rx_byte  (rx_byte),
        .rx_valid (rx_valid)
    );

    // ───── UART TX ────────────────────────────────────────────────────
    logic [7:0] tx_byte;
    logic       tx_valid;
    logic       tx_ready;

    uart_tx #(.CLK_FREQ_HZ(CLK_FREQ_HZ), .BAUD_RATE(BAUD_RATE)) u_uart_tx (
        .clk      (CLK100MHZ),
        .rst_n    (rst_n),
        .tx_byte  (tx_byte),
        .tx_valid (tx_valid),
        .tx_ready (tx_ready),
        .tx       (uart_txd_in)
    );

    // ───── AAA engine core ────────────────────────────────────────────
    wire        key_secure;
    wire [31:0] packets_total;
    wire [31:0] packets_missed_by_eve;
    wire [31:0] cumulative_secure_rounds;
    wire [3:0]  fsm_state_dbg;

    aaa_engine #(
        .KEY_BYTES     (KEY_BYTES),
        .PAYLOAD_BYTES (512),
        .SEED          (SEED)
    ) u_engine (
        .clk                       (CLK100MHZ),
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

    // ───── LEDs ───────────────────────────────────────────────────────
    assign led = {fsm_state_dbg[2:0], key_secure};

endmodule

`default_nettype wire
