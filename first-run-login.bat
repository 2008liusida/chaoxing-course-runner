@echo off
chcp 65001 >nul
setlocal

rem ============================================================
rem  first-run-login.bat - 只启动浏览器（可选）
rem
rem  这一步是可选的：直接双击 Start.bat 效果相同，
rem  它会自己启动浏览器并打开登录页。
rem
rem  保留本文件是为了"只想先把浏览器开起来、稍后再跑工具"的场景。
rem
rem  浏览器使用独立配置目录（browser-profile），与你日常浏览器隔离。
rem  工具不保存登录凭据，每次运行请按提示正常登录。
rem ============================================================

set "HERE=%~dp0"
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%Run.ps1" -LaunchOnly

echo.
echo ============================================================
echo  Next steps / 下一步:
echo    1) Log in to Chaoxing in the browser window that just opened.
echo       请在刚打开的浏览器窗口里登录学习通。
echo    2) Double-click Start.bat, then open your course's student
echo       study page in that browser window.
echo       然后双击 Start.bat，并在该浏览器窗口里打开课程的
echo       「学生学习页面」。
echo.
echo  Note: this step is optional - Start.bat does the same thing.
echo  说明：这一步是可选的，直接双击 Start.bat 效果相同。
echo ============================================================
pause
endlocal
