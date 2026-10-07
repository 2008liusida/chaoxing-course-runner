@echo off
chcp 65001 >nul
setlocal

rem ============================================================
rem  ClearCache.bat - 清理浏览器缓存
rem
rem  工具运行会在 browser-profile 里累积浏览器数据，用久了
rem  可达数百 MB（绝大部分是 Edge 的网页缓存，与工具无关）。
rem  双击本文件即可清理。
rem
rem  用法：
rem    双击            清理缓存（保留浏览器配置）
rem    -All            连整个配置目录一起删除
rem
rem  清理会先关闭工具专用的浏览器实例，不影响你日常用的浏览器。
rem  运行中请勿清理 —— 正在刷的课会中断。
rem ============================================================

set "HERE=%~dp0"
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%scripts\Clear-Cache.ps1" %*

echo.
pause
endlocal
