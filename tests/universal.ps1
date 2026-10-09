<#
.SYNOPSIS
    通用性测试：对所有版本的夹具，验证"通用发现"都能跑通完整功能。

.DESCRIPTION
    背景：原来每个平台一套写死的选择器（legacy / mooc2 / coursetree），
    每加一个功能都要在每个平台上重做一遍 —— 结果就是"换个学校功能就没了"。

    这套测试的作用是：把"通用发现"（Discover-CoursePage）当作一条独立路径，
    对每个夹具分别验证它能产出可用的选择器，并且读课节、读章节、切课都正常。
    只要它对这些夹具都成立，遇到第四种、第五种结构时也能尽力而为。

    夹具：
      studentstudy.html      legacy 风格（h5[id^=cur] + .ncells + 状态圆点）
      unknown-version.html   刻意与已知版本不同（假 class 名，只保留平台约定）

.PARAMETER DebugPort
    调试端口，默认 9230（与日常用的 9222 分开，避免打断正在跑的刷课）。
#>
[CmdletBinding()]
param(
    [int]$DebugPort = 9230,
    [int]$BasePort = 8880
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

Write-Host '=== 通用性测试：通用发现对各版本夹具是否都成立 ===' -ForegroundColor Cyan

# 起一个夹具服务（两个页面都在同一目录里）
$serverJob = $null
$prof = Join-Path $env:TEMP ('ccr-uni-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$browserStarted = $false

try {
    $serverJob = Start-TestServer -Directory (Join-Path $PSScriptRoot 'fixture') -Port $BasePort
    $up = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        try {
            $r = Invoke-WebRequest -Uri ("http://127.0.0.1:$BasePort/unknown-version.html") -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -eq 200) { $up = $true; break }
        } catch { }
    }
    if (-not $up) { throw '夹具服务起不来' }

    # 调试浏览器（独立端口，不碰日常那个）
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
        @{ File = 'unknown-version.html'; Name = '未知结构夹具'; ExpectLessons = 6;  ExpectChapters = 3 },
        @{ File = 'studentstudy.html';    Name = 'legacy 结构夹具'; ExpectLessons = 9;  ExpectChapters = 0 }
    )) {
        Write-Host ''
        Write-Host ('—— ' + $case.Name + ' ——') -ForegroundColor Gray

        $url = 'http://127.0.0.1:{0}/{1}' -f $BasePort, $case.File
        [void](Invoke-RestMethod -Method Put -Uri (
            'http://127.0.0.1:{0}/json/new?{1}' -f $DebugPort, [uri]::EscapeDataString($url)))
        Start-Sleep -Seconds 3

        $tabs = @(Get-CdpTargets -Port $DebugPort)
        $page = $tabs | Where-Object { $_.url -match [regex]::Escape($case.File.Split('.')[0]) } | Select-Object -First 1
        if (-not $page) { Check ($case.Name + ' 页面已打开') $false; continue }
        $s = New-CdpSession -Page $page -Port $DebugPort

        # 1) 通用发现必须成立
        $disc = Discover-CoursePage -Session $s -RawSelectors $raw -DirContextId 0
        foreach ($why in @($disc.Reasons)) { Write-Host ('     · ' + $why) -ForegroundColor DarkGray }
        Check ($case.Name + '：通用发现成功') ($disc.Ok -eq $true) $(if (-not $disc.Ok) { $disc.Message } else { '' })
        if (-not $disc.Ok) { continue }

        $sel = $disc.Selectors

        # 2) 用发现出来的选择器读课节
        $lessons = @(Get-LessonList -Session $s -Selectors $sel -DirContextId 0)
        Check ($case.Name + '：读出 ' + $case.ExpectLessons + ' 个课节') `
            ($lessons.Count -eq $case.ExpectLessons) ('实际 ' + $lessons.Count)

        # 3) 章节树
        $tree = Get-ChapterTree -Session $s -Selectors $sel -DirContextId 0
        if ($case.ExpectChapters -gt 0) {
            Check ($case.Name + '：分出 ' + $case.ExpectChapters + ' 章') `
                ($tree.ChapterCount -eq $case.ExpectChapters) ('实际 ' + $tree.ChapterCount)
        } else {
            Check ($case.Name + '：章节树不报错（该夹具无章）') ($tree.ChapterCount -ge 0)
        }

        # 4) 范围解析（有章时按章选，没章时按序号）
        if ($lessons.Count -gt 0) {
            $rng = Resolve-LessonRange -Chapters $tree.Chapters -From '' -To ''
            Check ($case.Name + '：范围解析可用') ($rng.Ok -eq $true)
        }

        # 5) 切课
        if ($lessons.Count -ge 2) {
            $target = $lessons[1].Id
            [void](Switch-Lesson -Session $s -Selectors $sel -LessonId $target -DirContextId 0)
            Start-Sleep -Seconds 2
            $cur = Get-CurrentLessonId -Session $s -Selectors $sel
            Check ($case.Name + '：切课成功') ($cur -eq $target) ('期望 ' + $target + ' 实际 ' + $cur)
        }
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
    Write-Host ('===== 通用性测试: 通过 ' + $ok + ' 项 =====') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('===== 通用性测试: 通过 ' + $ok + ' 项，失败 ' + $fail + ' 项 =====') -ForegroundColor Red
    exit 1
}
