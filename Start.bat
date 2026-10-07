@echo off
chcp 65001 >nul
cls
setlocal
rem ============================================================
rem  ChaoxingCourseRunner - main entry point
rem  Just double-click this file.
rem
rem  Optional arguments (pass after the file name):
rem    Start.bat -DryRun
rem    Start.bat -LaunchOnly
rem    Start.bat -LessonIds 1222994220,1222994221 -MaxLessons 2
rem    Start.bat -NoForeground
rem ============================================================

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