@echo off
rem ============================================================
rem  first-run-login.bat - start the browser only (optional)
rem
rem  Optional: double-clicking Start.bat does the same thing,
rem  it starts the browser and opens the login page by itself.
rem
rem  Kept for the case where you only want the browser open now
rem  and run the tool later.
rem
rem  The browser uses its own profile directory (browser-profile),
rem  isolated from your daily browser.
rem  Credentials are never stored by this tool.
rem
rem  This file is intentionally ASCII-only (see Run-Interactive.bat).
rem ============================================================

setlocal
set "HERE=%~dp0"
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%Run.ps1" -LaunchOnly

echo.
echo ============================================================
echo  Next steps:
echo    1) Log in to Chaoxing in the browser window that opened.
echo    2) Double-click Start.bat, then open your course's
echo       student-study page in that browser window.
echo.
echo  This step is optional - Start.bat does the same thing.
echo ============================================================
pause
endlocal
