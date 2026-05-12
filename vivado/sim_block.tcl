# vivado/sim_block.tcl
#
# Drives Vivado's xsim from the command line for a single testbench.
#
# Usage (from the repo root):
#   vivado -mode batch -source vivado/sim_block.tcl -tclargs tb_xorshift32
#   vivado -mode batch -source vivado/sim_block.tcl -tclargs tb_aaa_engine_top
#
# The TB's $readmemh / $fopen paths are RELATIVE to the directory Vivado
# is launched from, so the script chdirs to <repo>/tb so paths like
# "vectors/payload_0003.hex" resolve.

set repo_root [file normalize [file join [file dirname [info script]] ..]]
set tb_name   [lindex $argv 0]
if {$tb_name eq ""} {
    error "sim_block.tcl: pass a testbench top, e.g. -tclargs tb_xorshift32"
}

set rtl_files [glob [file join $repo_root rtl *.sv]]
set tb_files  [glob [file join $repo_root tb  *.sv]]

# Switch CWD to <repo>/tb so $readmemh("vectors/...") resolves.
cd [file join $repo_root tb]

# Project-less compile + elaborate + simulate
exec xvlog -sv -d SIMULATION {*}$rtl_files {*}$tb_files >@ stdout 2>@ stdout
exec xelab --timescale 1ns/1ps -debug typical $tb_name -s ${tb_name}_sim >@ stdout 2>@ stdout
exec xsim ${tb_name}_sim -runall >@ stdout 2>@ stdout

puts "==== sim_block.tcl DONE: $tb_name ===="
