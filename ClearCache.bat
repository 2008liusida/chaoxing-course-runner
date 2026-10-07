@echo off
rem ============================================================
rem  ClearCache.bat - clear browser cache
rem
rem  The tool accumulates browser data under browser-profile.
rem  Most of it is Edge's own page cache and is unrelated to this
rem  tool. Double-click this file to reclaim the space.
rem
rem  Usage:
rem    double-click        clear cache only (keeps the profile)
rem    ClearCache.bat -All delete the whole profile directory
rem
rem  The script closes the tool's own browser instance first
rem  (matched by profile path - your daily browser is untouched).
rem
rem  Do not run this while the tool is playing: the running
rem  lesson will be interrupted.
rem
rem  This file is intentionally ASCII-only (see Run-Interactive.bat).
rem ============================================================

setlocal
set "HERE=%~dp0"
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%scripts\Clear-Cache.ps1" %*

echo.
pause
endlocal
