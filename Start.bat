@echo off
rem ============================================================
rem  Start.bat - main entry point
rem
rem  Just double-click this file.
rem
rem  What happens:
rem    1) A dedicated browser starts (separate profile)
rem    2) The Chaoxing login page opens - log in there
rem    3) Open your course student-study page in that browser
rem    4) The terminal lists pending lessons -> press y
rem
rem  Steps 2 and 3 need no terminal action; the tool watches the
rem  page and continues by itself. Only the final y is needed.
rem
rem  Optional arguments (pass after the file name):
rem    Start.bat -DryRun
rem    Start.bat -LaunchOnly
rem    Start.bat -LessonIds 1222994220,1222994221 -MaxLessons 2
rem    Start.bat -NoForeground
rem
rem  This file is intentionally ASCII-only (see Run-Interactive.bat).
rem ============================================================

setlocal
set "HERE=%~dp0"
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%Run.ps1" %*

echo.
echo ============================================================
echo  Finished. Log file: logs\run.log
echo ============================================================
pause
endlocal
