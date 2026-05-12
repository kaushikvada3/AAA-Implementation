@echo off
REM Run every unit + integration testbench in sequence.
REM Invoke from a Vivado-aware shell (xvlog/xelab/xsim on PATH).

setlocal
set REPO_ROOT=%~dp0..
cd /d "%REPO_ROOT%\tb"

for %%T in (
    tb_xorshift32
    tb_key_accumulator
    tb_bit_select_fold
    tb_payload_buffer
    tb_secrecy_monitor
    tb_key_export
    tb_aaa_engine_top
) do (
    echo ==== %%T ====
    xvlog -sv ..\rtl\*.sv %%T.sv || goto :err
    xelab --timescale 1ns/1ps -debug typical %%T -s %%T_sim || goto :err
    xsim %%T_sim -runall || goto :err
)

echo ==== ALL TESTBENCHES PASSED ====
endlocal
exit /b 0

:err
echo *** TESTBENCH FAILURE ***
endlocal
exit /b 1
