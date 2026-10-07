@echo off
rem ============================================================
rem  Diagnose.bat - environment self-check
rem
rem  Run this first when the tool will not start.
rem
rem  It checks: file presence, Mark-of-the-Web flags, execution
rem  policy, browser availability, port occupancy, script BOM,
rem  and whether the module loads.
rem
rem  This file is intentionally ASCII-only (see Start.bat).
rem ============================================================

setlocal
set "HERE=%~dp0"
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tests\diagnose-env.ps1" %*

echo.
pause
endlocal
