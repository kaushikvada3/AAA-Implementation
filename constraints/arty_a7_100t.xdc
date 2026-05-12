# constraints/arty_a7_100t.xdc
#
# Pin assignments for the Digilent Arty A7-100T (xc7a100tcsg324-1).
# Adapted from the official Digilent master XDC for this board.
# Only the pins used by aaa_engine_uart_wrap are uncommented.

# ------------ 100 MHz system clock ------------
set_property -dict { PACKAGE_PIN E3   IOSTANDARD LVCMOS33 } [get_ports { CLK100MHZ }]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { CLK100MHZ }]

# ------------ Reset push-button (CK_RST) ------------
# C2 is the dedicated Arty reset pin (active-low).
set_property -dict { PACKAGE_PIN C2   IOSTANDARD LVCMOS33 } [get_ports { ck_rst_n }]

# ------------ USB-UART bridge ------------
# Per Digilent master XDC the FT2232HQ exposes UART_RXD_OUT / UART_TXD_IN.
# From the FPGA's perspective:
#   uart_rxd_out  is the FPGA's RX  (host -> FPGA), pin A9
#   uart_txd_in   is the FPGA's TX  (FPGA -> host), pin D10
set_property -dict { PACKAGE_PIN A9   IOSTANDARD LVCMOS33 } [get_ports { uart_rxd_out }]
set_property -dict { PACKAGE_PIN D10  IOSTANDARD LVCMOS33 } [get_ports { uart_txd_in  }]

# ------------ LEDs (4) ------------
# led[0]=key_secure, led[3:1]=fsm_state_dbg[2:0]
set_property -dict { PACKAGE_PIN H5   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN J5   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN T9   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN T10  IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

# ------------ Bitstream config (SPI flash speed-ups) ------------
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO    [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
