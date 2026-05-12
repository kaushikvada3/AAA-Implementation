# vivado/build_project.tcl
#
# Non-project synthesis + implementation flow for the AAA engine on
# the Arty A7-100T (xc7a100tcsg324-1).
#
# Usage (from the repo root):
#   vivado -mode batch -source vivado/build_project.tcl \
#          -tclargs -key_bytes 16 -top aaa_engine_uart_wrap
#
# Defaults (no -tclargs): KEY_BYTES=16, top=aaa_engine_uart_wrap (bitstream).
# To synthesize the engine core only (for clean utilization numbers):
#   vivado -mode batch -source vivado/build_project.tcl \
#          -tclargs -key_bytes 16 -top aaa_engine -nobit

set repo_root [file normalize [file join [file dirname [info script]] ..]]
set build_dir [file join $repo_root build]
file mkdir $build_dir

# ----- parse -tclargs --------------------------------------------------------
set key_bytes 16
set top       "aaa_engine_uart_wrap"
set make_bit  1

for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -key_bytes { incr i; set key_bytes [lindex $argv $i] }
        -top       { incr i; set top       [lindex $argv $i] }
        -nobit     { set make_bit 0 }
        default    { puts "WARN: unknown tclarg $a" }
    }
}

set suffix [expr {$key_bytes * 8}]bit
puts "==== AAA build: top=$top  KEY_BYTES=$key_bytes  ($suffix) ===="

# ----- sources ---------------------------------------------------------------
set rtl_files [glob [file join $repo_root rtl *.sv]]
foreach f $rtl_files { puts "  + $f" }
read_verilog -sv $rtl_files

if {$top eq "aaa_engine_uart_wrap"} {
    read_xdc [file join $repo_root constraints arty_a7_100t.xdc]
}

# ----- synth -----------------------------------------------------------------
synth_design -top $top -part xc7a100tcsg324-1 -generic KEY_BYTES=$key_bytes
write_checkpoint -force [file join $build_dir post_synth_${suffix}.dcp]
report_utilization -file [file join $build_dir utilization_${suffix}.rpt]

# ----- implement (only for the UART-wrapped top with constraints) ------------
if {$top eq "aaa_engine_uart_wrap"} {
    opt_design
    place_design
    route_design

    write_checkpoint -force [file join $build_dir post_route_${suffix}.dcp]
    report_timing_summary -file [file join $build_dir timing_${suffix}.rpt]
    report_power           -file [file join $build_dir power_${suffix}.rpt]
    report_utilization     -hierarchical -file [file join $build_dir utilization_${suffix}.rpt]

    if {$make_bit} {
        write_bitstream -force [file join $build_dir aaa_engine_${suffix}.bit]
    }
} else {
    # Core-only synth: still report timing against a 100 MHz virtual clock.
    create_clock -name vclk -period 10.0
    set_input_delay  -clock vclk 2.0 [all_inputs]
    set_output_delay -clock vclk 2.0 [all_outputs]
    report_timing_summary -file [file join $build_dir timing_core_${suffix}.rpt]
    report_power           -file [file join $build_dir power_core_${suffix}.rpt]
}

puts "==== DONE.  Reports under $build_dir ===="
