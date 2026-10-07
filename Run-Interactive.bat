@echo off
chcp 65001 >nul
cls
setlocal

rem ============================================================
rem  Run-Interactive.bat - 交互式入口（推荐日常使用）
rem
rem  流程（按顺序）：
rem    [1/4] 启动专用浏览器
rem          独立配置目录，与你日常浏览器完全隔离
rem    [2/4] 登录学习通
rem          浏览器打开登录页 -> 你本人登录/扫码
rem          终端无需操作，工具检测到登录成功会自动继续
rem    [3/4] 打开目标课程
rem          你打开课程的「学生学习页面」（左目录右视频）
rem          终端无需操作，检测到课程页会自动继续
rem    [4/4] 确认并开始
rem          工具列出待处理课节 -> 你按 y / 回车
rem          -> 开始自动连播，一集接一集
rem
rem  说明：整个流程只需在终端按一次键（最后那步的 y）。
rem
rem  运行期间请勿最小化浏览器窗口，也不要切到其它标签页 ——
rem  页面不可见时浏览器会禁止加载视频（这是浏览器行为，不是工具问题）。
rem
rem  停止方式：按 Ctrl+C，或直接关闭本窗口。
rem            已经播完的课节不会重刷。
rem ============================================================

set "HERE=%~dp0"
set "PS=powershell.exe"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 set "PS=pwsh.exe"

"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%HERE%Run-Interactive.ps1" %*

echo.
echo ============================================================
echo  运行结束。详细日志在: logs\run.log
echo  如有课节未完成，日志里会列出课节 id 与原因。
echo ============================================================
pause
endlocal
