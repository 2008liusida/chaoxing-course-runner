<#
.SYNOPSIS
    验证"版本不认识时的兜底发现"（Discover-CoursePage）。

.DESCRIPTION
    加载 tests/fixture/unknown-version.html —— 一份刻意与已知三个版本
    都不相同的页面（假 class 名），但保留学习通跨版本稳定的约定。
    然后确认：
      1) 三个已知版本都认不出来（证明这确实是"未知结构"）
      2) Discover-CoursePage 能把结构找出来
      3) 用发现出来的选择器能正常读课节、切课

    如果没有这条兜底，第 1 步之后工具就会报"版本我不认识"退出。

.PARAMETER DebugPort
    调试端口，默认 9222。
.PARAMETER Port
    本地夹具服务的端口，默认 8898（与 run-fixture 的 8899 分开，便于同时跑）。
#>
[CmdletBinding()]
param(
    [int]$DebugPort = 9222,
    [int]$Port = 8898
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'TestServer.psm1') -Force -DisableNameChecking

$ok = 0
$fail = 0
function Check {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    if ($Pass) {
        Write-Host ('  [OK]   ' + $Name) -ForegroundColor Green
        $script:ok++
    } else {
        Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { ' -> ' + $Detail } else { '' })) -ForegroundColor Red
        $script:fail++
    }
}

$fixtureDir = Join-Path $PSScriptRoot 'fixture'
$baseUrl = "http://127.0.0.1:$Port/unknown-version.html"

Write-Host '=== 兜底发现测试（未知版本夹具）===' -ForegroundColor Cyan
Write-Host ''

$serverJob = Start-TestServer -Directory $fixtureDir -Port $Port
Start-Sleep -Seconds 2

$browserStarted = $false
try {
    # 调试端口：没有就自己起一个
    $portAlive = $false
    try {
        [void](Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/version" -f $DebugPort) -TimeoutSec 3)
        $portAlive = $true
    } catch { }

    if (-not $portAlive) {
        Write-Host '  调试端口上没有浏览器，启动一个…' -ForegroundColor Gray
        $fxProfile = Join-Path $env:TEMP ('ccr-unknown-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        $exe = Find-BrowserExe -Preferred 'edge'
        if (-not (Start-DebugBrowser -Exe $exe -Port $DebugPort -ProfileDir $fxProfile -StartUrl 'about:blank')) {
            throw '夹具浏览器起不来'
        }
        $browserStarted = $true
    }

    $target = Invoke-RestMethod -Method Put -Uri ("http://127.0.0.1:{0}/json/new?about:blank" -f $DebugPort)
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None).Wait(8000) | Out-Null
    $navMsg = @{ id = 1; method = 'Page.navigate'; params = @{ url = $baseUrl } } | ConvertTo-Json -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($navMsg)
    $ws.SendAsync((New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)),
        [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
        [System.Threading.CancellationToken]::None).Wait(5000) | Out-Null
    $ws.Dispose()
    Start-Sleep -Seconds 3

    # 取这一页做会话
    $tabs = @(Get-CdpTargets -Port $DebugPort)
    $page = $tabs | Where-Object { $_.url -match 'unknown-version' } | Select-Object -First 1
    if (-not $page) { throw '夹具页面没打开' }
    $s = New-CdpSession -Page $page -Port $DebugPort

    $raw = Import-CourseSelectors

    # ---- 1. 三个已知版本都应认不出来 ----
    Write-Host '—— 1. 先确认已知版本确实认不出来 ——' -ForegroundColor Gray
    $det = Resolve-Platform -Session $s -RawSelectors $raw
    Check '已知版本均未命中（这是未知结构）' ($det.Version -eq '') ('实际识别为: ' + $det.Version)

    # ---- 2. 兜底发现 ----
    Write-Host ''
    Write-Host '—— 2. 兜底发现 ——' -ForegroundColor Gray
    $disc = Discover-CoursePage -Session $s -RawSelectors $raw -DirContextId 0
    foreach ($why in @($disc.Reasons)) { Write-Host ('     · ' + $why) -ForegroundColor DarkGray }
    Check '发现成功' ($disc.Ok -eq $true) $(if (-not $disc.Ok) { $disc.Message } else { '' })
    if (-not $disc.Ok) { throw ('兜底发现失败: ' + $disc.Message) }

    Check '课节节点选择器已找出' (-not [string]::IsNullOrWhiteSpace([string]$disc.Selectors['LessonNode'])) `
        ([string]$disc.Selectors['LessonNode'])
    Check '切课函数已找出' ([string]$disc.Selectors['SwitchFunction'] -eq 'getTeacherAjax') `
        ([string]$disc.Selectors['SwitchFunction'])
    Check '未完成计数选择器已找出' (-not [string]::IsNullOrWhiteSpace([string]$disc.Selectors['UnfinishedCount'])) `
        ([string]$disc.Selectors['UnfinishedCount'])
    Check '任务点状态选择器已找出' (-not [string]::IsNullOrWhiteSpace([string]$disc.Selectors['JobIcon'])) `
        ([string]$disc.Selectors['JobIcon'])

    # ---- 3. 用发现出来的选择器读课节 ----
    Write-Host ''
    Write-Host '—— 3. 用发现的选择器读课节 ——' -ForegroundColor Gray
    $lessons = @(Get-LessonList -Session $s -Selectors $disc.Selectors -DirContextId 0)
    Check '读到 6 个课节' ($lessons.Count -eq 6) ('实际 ' + $lessons.Count)

    if ($lessons.Count -eq 6) {
        $done = @($lessons | Where-Object { -not $_.Unfinished })
        Check '识别出 2 个已完成' ($done.Count -eq 2) ('实际 ' + $done.Count)
        Check '第一个课节完成' ((-not $lessons[0].Unfinished) -eq $true)
        Check '第三个课节未完成' ($lessons[2].Unfinished -eq $true)
        Check '未完成计数读到' ($lessons[2].UnfinishedCount -eq 2) ('实际 ' + $lessons[2].UnfinishedCount)
    }

    # ---- 4. 切课能生效 ----
    Write-Host ''
    Write-Host '—— 4. 切换课节 ——' -ForegroundColor Gray
    $how = Switch-Lesson -Session $s -Selectors $disc.Selectors -LessonId '9000000004' -DirContextId 0
    Start-Sleep -Seconds 2
    $cur = Get-CurrentLessonId -Session $s -Selectors $disc.Selectors
    Check '切到 9000000004 成功' ($cur -eq '9000000004') ('方式=' + $how + ' 当前=' + $cur)

} finally {
    if ($serverJob) { Stop-Job $serverJob -ErrorAction SilentlyContinue; Remove-Job $serverJob -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ('===== 兜底发现测试: 通过 ' + $ok + ' 项 =====') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('===== 兜底发现测试: 通过 ' + $ok + ' 项，失败 ' + $fail + ' 项 =====') -ForegroundColor Red
    exit 1
}
