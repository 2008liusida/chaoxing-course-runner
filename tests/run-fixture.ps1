<#
.SYNOPSIS
    离线自测：对 tests\fixture 的夹具页面跑一遍完整链路。

.DESCRIPTION
    夹具复刻了学习通课程页的真实结构与 URL 路径：
      #curChapterId、h5[id^=cur]、.roundpoint(orange/blue)，
      以及三层 iframe：studentstudy -> knowledge/cards -> ananas/modules/video，
      内容层里的 .ans-job-icon / .ans-job-finished。
    因此可以在不接触真实课程的前提下验证：
      识别未完成课节 -> 切课 -> 播放 -> 播完登记完成 -> 自动进入下一节

    步骤：
      1. 用 tests\TestServer.psm1 起本地静态服务（不依赖 Python）
      2. 打开夹具页
      3. 用 config.fixture.psd1 跑 Run.ps1
      4. 打印日志摘要

.PARAMETER SkipServer
    已经有本地服务在 8899 端口时使用。
.PARAMETER DebugPort
    浏览器调试端口，默认 9222（要求端口上已有浏览器实例）。
.PARAMETER LessonIds
    要跑的课节 id，默认取夹具里前两节。

.EXAMPLE
    .\tests\run-fixture.ps1
#>

[CmdletBinding()]
param(
    [switch]$SkipServer,
    [int]$DebugPort = 9222,
    [string]$LessonIds = '1222994220,1222994221'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Split-Path -Parent $PSScriptRoot
$fixtureDir = Join-Path $PSScriptRoot 'fixture'
$port = 8899
$baseUrl = "http://127.0.0.1:$port/studentstudy.html"

Import-Module (Join-Path $PSScriptRoot 'TestServer.psm1') -Force -DisableNameChecking

# ---------------- 1. 本地静态服务 ----------------
$serverJob = $null
if (-not $SkipServer) {
    $probe = $null
    try { $probe = Invoke-WebRequest -Uri $baseUrl -TimeoutSec 3 -UseBasicParsing } catch { }

    if ($probe) {
        Write-Host '[信息] 8899 端口已有服务，直接使用' -ForegroundColor Gray
    } else {
        Write-Host "[信息] 启动本地夹具服务 $baseUrl" -ForegroundColor Gray
        $serverJob = Start-TestServer -Directory $fixtureDir -Port $port
        if (-not (Wait-TestServer -Url $baseUrl)) {
            if ($serverJob) { Stop-Job $serverJob -ErrorAction SilentlyContinue; Remove-Job $serverJob -Force -ErrorAction SilentlyContinue }
            throw '本地夹具服务启动失败'
        }
    }
}

try {
    # ---------------- 2. 打开夹具页 ----------------
    Write-Host '[信息] 打开夹具页面' -ForegroundColor Gray
    $target = $null
    try {
        $target = Invoke-RestMethod -Method Put -Uri ("http://127.0.0.1:{0}/json/new?about:blank" -f $DebugPort) -TimeoutSec 8
    } catch {
        throw "无法连接调试端口 $DebugPort（可先用 Run.ps1 -LaunchOnly 启动浏览器）: $($_.Exception.Message)"
    }

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).Wait(8000) | Out-Null
    $navMsg = @{ id = 1; method = 'Page.navigate'; params = @{ url = $baseUrl } } | ConvertTo-Json -Compress -Depth 5
    $navBytes = [System.Text.Encoding]::UTF8.GetBytes($navMsg)
    $ws.SendAsync(
        (New-Object System.ArraySegment[byte] -ArgumentList @(, $navBytes)),
        [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None
    ).Wait(8000) | Out-Null
    Start-Sleep -Seconds 6
    $ws.Dispose()

    # ---------------- 3. 跑工具 ----------------
    $logPath = Join-Path $root 'logs\fixture.log'
    Remove-Item $logPath -Force -ErrorAction SilentlyContinue

    Write-Host '[信息] 运行 Run.ps1（夹具配置）' -ForegroundColor Gray
    & (Join-Path $root 'Run.ps1') `
        -ConfigFile (Join-Path $root 'config.fixture.psd1') `
        -DebugPort $DebugPort `
        -LessonIds $LessonIds

    # ---------------- 4. 结果摘要 ----------------
    Write-Host ''
    Write-Host '===== 夹具日志摘要 =====' -ForegroundColor Cyan
    if (Test-Path $logPath) {
        Get-Content $logPath -Encoding UTF8 |
            Where-Object { $_ -match '课节|完成|跳过|播放|登记|刷新' } |
            Select-Object -First 50 |
            ForEach-Object { Write-Host $_ }
    } else {
        Write-Host '（没有生成日志）' -ForegroundColor Yellow
    }
} finally {
    if ($serverJob) {
        Stop-Job $serverJob -ErrorAction SilentlyContinue
        Remove-Job $serverJob -Force -ErrorAction SilentlyContinue
    }
}
