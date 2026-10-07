@echo off
chcp 65001 >nul
setlocal

rem ============================================================
rem  Diagnose.bat - 环境自检
rem
rem  跑不起来时先双击这个，把窗口里的全部内容复制下来。
rem  它不会修改任何东西，只读检查。
rem ============================================================

set "HERE=%~dp0"
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 set "PS=pwsh.exe"

echo ============================================================
echo  ChaoxingCourseRunner 环境自检
echo ============================================================
echo.

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%tests\diagnose-env.ps1"

echo.
echo ============================================================
echo  自检结束。请把上面的内容复制给维护者。
echo ============================================================
pause
endlocal
