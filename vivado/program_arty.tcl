# vivado/program_arty.tcl
#
# Program the Arty A7-100T via the on-board FT2232HQ JTAG. Invoke with:
#   vivado -mode batch -source vivado/program_arty.tcl -tclargs <path/to/.bit>
#
# Requires Vivado's hw_server / cs_server to be reachable on localhost:3121.
# Vivado batch mode starts these automatically when open_hw_manager runs.

set bit_path [lindex $argv 0]
if {$bit_path eq ""} {
    error "Usage: program_arty.tcl <bitstream.bit>"
}
if {![file exists $bit_path]} {
    error "Bitstream not found: $bit_path"
}

puts "==== Programming Arty A7-100T with $bit_path ===="

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target

# List devices for sanity
set devs [get_hw_devices]
puts "Discovered devices: $devs"

# The Arty A7-100T's only programmable device is the xc7a100t.
set arty_dev [get_hw_devices xc7a100t_0]
if {[llength $arty_dev] == 0} {
    # Fallback: any xc7a* device
    set arty_dev [lindex [get_hw_devices -filter {PART =~ "xc7a*"}] 0]
}
puts "Target device: $arty_dev"

current_hw_device $arty_dev
set_property PROGRAM.FILE $bit_path $arty_dev
program_hw_devices $arty_dev
refresh_hw_device $arty_dev

puts "==== Programmed.  Closing hardware target. ===="
close_hw_target
disconnect_hw_server
close_hw_manager
