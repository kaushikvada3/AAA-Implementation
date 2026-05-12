@echo off
REM Build both 128-bit and 256-bit bitstreams, plus core-only synth runs
REM that produce the clean utilization/timing/power reports for the paper.
REM
REM Invoke from a Vivado-aware shell (vivado.exe on PATH).

setlocal
set REPO_ROOT=%~dp0..
cd /d "%REPO_ROOT%"

REM Bitstream builds (UART-wrapped top, with XDC)
vivado -mode batch -source vivado\build_project.tcl -tclargs -key_bytes 16 -top aaa_engine_uart_wrap || goto :err
vivado -mode batch -source vivado\build_project.tcl -tclargs -key_bytes 32 -top aaa_engine_uart_wrap || goto :err

REM Core-only synth runs (no XDC, no bitstream) for clean engine area/power numbers
vivado -mode batch -source vivado\build_project.tcl -tclargs -key_bytes 16 -top aaa_engine -nobit || goto :err
vivado -mode batch -source vivado\build_project.tcl -tclargs -key_bytes 32 -top aaa_engine -nobit || goto :err

echo ==== ALL BUILDS DONE.  See build\*.rpt and build\aaa_engine_*.bit ====
endlocal
exit /b 0

:err
echo *** BUILD FAILURE ***
endlocal
exit /b 1
