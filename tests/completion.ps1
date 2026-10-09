<#
.SYNOPSIS
    验证"完成判定"对各版本夹具都正确。

.DESCRIPTION
    这是"换个学校就失效"的重灾区：原来各版本靠不同的状态标记
    （legacy 看 span.roundpoint 的 class、coursetree 看 input.jobUnfinishCount），
    一旦页面结构变了就读不到，于是要么判成全部未完成（反复重刷）、
    要么判成全部完成（一节不刷）。

    通用判据（三个已知版本 + 未知结构都成立）：
      · 课节自己范围内有"未完成计数"隐藏 input 且值 > 0  -> 未完成
      · 那个 input 根本不存在                            -> 已完成
    两个夹具的标记名字刻意不同（jobUnfinishCount / leftTaskNum），
    用来证明判定不依赖具体名字。

.PARAMETER DebugPort
    调试端口，默认 9231（与日常用的 9222、通用性测试的 9230 分开）。
#>
[CmdletBinding()]
param(
    [int]$DebugPort = 9231,
    [int]$BasePort = 8881
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'TestServer.psm1') -Force -DisableNameChecking

$ok = 0; $fail = 0
function Check {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    if ($Pass) { Write-Host ('  [OK]   ' + $Name) -ForegroundColor Green; $script:ok++ }
    else {
        Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { ' -> ' + $Detail } else { '' })) -ForegroundColor Red
        $script:fail++
    }
}

Write-Host '=== 完成判定通用性测试 ===' -ForegroundColor Cyan

$serverJob = $null
$prof = Join-Path $env:TEMP ('ccr-done-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$browserStarted = $false

try {
    $serverJob = Start-TestServer -Directory (Join-Path $PSScriptRoot 'fixture') -Port $BasePort
    $up = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $r = Invoke-WebRequest -Uri ("http://127.0.0.1:$BasePort/studentstudy.html") -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -eq 200) { $up = $true; break }
        } catch { }
    }
    if (-not $up) { throw '夹具服务起不来' }

    $alive = $false
    try { [void](Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/version" -f $DebugPort) -TimeoutSec 3); $alive = $true } catch { }
    if (-not $alive) {
        $exe = Find-BrowserExe -Preferred 'edge'
        [void](Start-DebugBrowser -Exe $exe -Port $DebugPort -ProfileDir $prof -StartUrl 'about:blank')
        $browserStarted = $true
    }
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        try { [void](Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/version" -f $DebugPort) -TimeoutSec 3); $alive = $true; break } catch { }
    }
    if (-not $alive) { throw '调试端口起不来' }

    $raw = Import-CourseSelectors

    foreach ($case in @(
        @{ File = 'studentstudy.html';    Name = 'legacy 夹具'; Done = 5; Undone = 4 },
        @{ File = 'unknown-version.html'; Name = '未知结构夹具'; Done = 2; Undone = 4 }
    )) {
        Write-Host ''
        Write-Host ('—— ' + $case.Name + ' ——') -ForegroundColor Gray

        $url = 'http://127.0.0.1:{0}/{1}' -f $BasePort, $case.File
        [void](Invoke-RestMethod -Method Put -Uri (
            'http://127.0.0.1:{0}/json/new?{1}' -f $DebugPort, [uri]::EscapeDataString($url)))
        Start-Sleep -Seconds 3

        $tabs = @(Get-CdpTargets -Port $DebugPort)
        $key = $case.File.Split('.')[0]
        $page = $tabs | Where-Object { $_.url -match [regex]::Escape($key) } | Select-Object -First 1
        if (-not $page) { Check ($case.Name + ' 页面已打开') $false; continue }
        $s = New-CdpSession -Page $page -Port $DebugPort

        $disc = Discover-CoursePage -Session $s -RawSelectors $raw -DirContextId 0
        if (-not $disc.Ok) { Check ($case.Name + ' 通用发现成功') $false $disc.Message; continue }

        $lessons = @(Get-LessonList -Session $s -Selectors $disc.Selectors -DirContextId 0)
        Check ($case.Name + '：读出全部课节') ($lessons.Count -eq ($case.Done + $case.Undone)) `
            ('实际 ' + $lessons.Count)

        $done = @($lessons | Where-Object { -not $_.Unfinished })
        $undone = @($lessons | Where-Object { $_.Unfinished })
        Check ($case.Name + ('：判定已完成 ' + $case.Done + ' 节')) ($done.Count -eq $case.Done) ('实际 ' + $done.Count)
        Check ($case.Name + ('：判定未完成 ' + $case.Undone + ' 节')) ($undone.Count -eq $case.Undone) ('实际 ' + $undone.Count)

        # 已完成的节，未完成计数必须读到 0（而不是 -1 或读不到）
        $badDone = @($done | Where-Object { $_.UnfinishedCount -ne 0 })
        Check ($case.Name + '：已完成节的计数为 0') ($badDone.Count -eq 0) `
            ('异常 ' + $badDone.Count + ' 节')

        # 未完成的节，计数必须 > 0
        $badUndone = @($undone | Where-Object { $_.UnfinishedCount -le 0 })
        Check ($case.Name + '：未完成节的计数 > 0') ($badUndone.Count -eq 0) `
            ('异常 ' + $badUndone.Count + ' 节')

        Write-Host ('     已完成: ' + (@($done | ForEach-Object { $_.Id }) -join ', ')) -ForegroundColor DarkGray
        Write-Host ('     未完成: ' + (@($undone | ForEach-Object { $_.Id + '(' + $_.UnfinishedCount + ')' }) -join ', ')) -ForegroundColor DarkGray
    }

} finally {
    if ($serverJob) { Stop-Job $serverJob -ErrorAction SilentlyContinue; Remove-Job $serverJob -Force -ErrorAction SilentlyContinue }
    if ($browserStarted) {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -like ('*' + (Split-Path $prof -Leaf) + '*') } |
            ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch { } }
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ('===== 完成判定测试: 通过 ' + $ok + ' 项 =====') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('===== 完成判定测试: 通过 ' + $ok + ' 项，失败 ' + $fail + ' 项 =====') -ForegroundColor Red
    exit 1
}
