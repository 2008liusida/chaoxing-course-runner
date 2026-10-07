<#
.SYNOPSIS
    夹具页与选择器的一致性检查（不含播放）。
.NOTES
    直接用工具自身的模块读取夹具页，验证"选择器 <-> 夹具结构"是否对齐。
    这是最轻量的回归测试：不含浏览器启动、不含播放。
#>

[CmdletBinding()]
param(
    [int]$DebugPort = 9222,
    [string]$FixtureUrl = 'http://127.0.0.1:8899/studentstudy.html'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking

$selectors = Import-CourseSelectors

function Get-FixturePage {
    param([int]$Port, [string]$UrlPattern)
    foreach ($t in (Get-CdpTargets -Port $Port)) {
        if ($t.type -ne 'page') { continue }
        if ($t.url -match $UrlPattern) { return $t }
    }
    return $null
}

$page = Get-FixturePage -Port $DebugPort -UrlPattern '8899'
if (-not $page) {
    Write-Output "夹具页未打开，先创建：$FixtureUrl"
    $created = Invoke-RestMethod -Method Put -Uri ("http://127.0.0.1:{0}/json/new?about:blank" -f $DebugPort) -TimeoutSec 8
    $session = New-CdpSession -Page $created -Port $DebugPort
    Send-Cdp -Session $session -Method 'Page.navigate' -Params @{ url = $FixtureUrl } | Out-Null
    Start-Sleep -Seconds 6
} else {
    Write-Output ("使用已打开的夹具页: " + $page.url)
    $session = New-CdpSession -Page $page -Port $DebugPort
}

try {
    $fail = 0
    function Assert($name, $actual, $expected) {
        $ok = ("$actual" -eq "$expected")
        if (-not $ok) { $script:fail++ }
        Write-Output ("  [{0}] {1}: 实际={2} 期望={3}" -f $(if ($ok) { 'OK' } else { 'FAIL' }), $name, $actual, $expected)
    }

    Write-Output '--- 页面识别 ---'
    Assert 'Test-CoursePage' (Test-CoursePage -Session $session -Selectors $selectors) 'True'

    Write-Output '--- 当前课节 ---'
    $cur = Get-CurrentLessonId -Session $session -Selectors $selectors
    Write-Output ("  Get-CurrentLessonId = $cur")
    Assert 'Get-UrlLessonId' (Get-UrlLessonId -Session $session) $cur

    Write-Output '--- 课程目录 ---'
    $lessons = @(Get-LessonList -Session $session -Selectors $selectors)
    Write-Output ("  读到课节数 = " + $lessons.Count)
    if ($lessons.Count -eq 0) {
        $fail++
        Write-Output '  [FAIL] 目录为空：夹具页没加载好，或选择器与夹具不一致'
    } else {
        $unfinished = @($lessons | Where-Object { $_.Unfinished })
        Write-Output ("  已完成 = " + ($lessons.Count - $unfinished.Count) + "，未完成 = " + $unfinished.Count)
        Write-Output ("  未完成课节 id: " + (@($unfinished | ForEach-Object { $_.Id }) -join ', '))
        foreach ($l in $lessons) {
            Write-Output ("    " + $l.Id + "  unfinished=" + $l.Unfinished + "  dot=[" + $l.StateClass + "]")
        }
    }

    Write-Output '--- 切课 ---'
    if ($lessons.Count -ge 2) {
        $target = $lessons[1].Id
        $how = Switch-Lesson -Session $session -Selectors $selectors -LessonId $target -ForceClick
        $okSwitch = Wait-LessonCurrent -Session $session -Selectors $selectors -LessonId $target -TimeoutSeconds 20
        Assert "切课到 $target（方式 $how）" $okSwitch 'True'
    }

    Write-Output ''
    if ($fail -eq 0) { Write-Output '夹具一致性检查通过' } else { Write-Output ("夹具一致性检查失败项: " + $fail); exit 1 }
} finally {
    Close-CdpSession -Session $session
}
