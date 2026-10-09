<#
.SYNOPSIS
    审计：工具还剩多少"逐平台特判"，还有哪些没做到通用。

.DESCRIPTION
    这个脚本不测功能，只把现状摊开：
      · 通用路径（Discover-CoursePage）实际能推出哪些选择器
      · 哪些地方仍然依赖写死的版本名
      · 选择器表里各版本块有多少条是"只有它自己才用得到"的
    目的是回答"做到全通用了没有"，而不是给自己打分。

    只读，不启浏览器、不碰页面。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking

Write-Host '=== 通用性审计 ===' -ForegroundColor Cyan
Write-Host ''

# ---- 1) 通用发现能产出哪些键 ----
Write-Host '1) 通用发现（Discover-CoursePage）产出的选择器键：' -ForegroundColor Gray
$disc = (Get-Command Discover-CoursePage).Definition
$keys = [regex]::Matches($disc, "\`$merged\['([A-Za-z]+)'\]") | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique
foreach ($k in $keys) { Write-Host ('     ' + $k) }
Write-Host ('   共 ' + @($keys).Count + ' 个键') -ForegroundColor DarkGray
Write-Host ''

# ---- 2) 选择器表：各版本块与 common 的差异 ----
Write-Host '2) 选择器表里各版本块的独有键（只有那个版本才需要的）：' -ForegroundColor Gray
$raw = Import-CourseSelectors
$commonKeys = @($raw.common.Keys)
foreach ($ver in @('legacy', 'mooc2', 'coursetree')) {
    $vk = @($raw[$ver].Keys)
    $only = @($vk | Where-Object { $commonKeys -notcontains $_ })
    $same = @($vk | Where-Object { $commonKeys -contains $_ -and $raw[$ver][$_] -eq $raw.common[$_] })
    Write-Host ('     ' + $ver.PadRight(11) + ' 共 ' + $vk.Count + ' 键，其中 common 里没有的 ' + $only.Count + ' 个: ' + ($only -join ', ')) -ForegroundColor DarkGray
}
Write-Host ''

# ---- 3) 仍按版本名分支的代码 ----
Write-Host '3) 仍然按版本名分支的代码位置：' -ForegroundColor Gray
$hits = @()
foreach ($f in (Get-ChildItem $root -Recurse -Include *.ps1, *.psm1 -File |
        Where-Object { $_.FullName -notmatch '\\(\.git|tests\\fixture|work)\\' })) {
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, (New-Object System.Text.UTF8Encoding($false)))) {
        $n++
        $t = $line.Trim()
        if ($t.StartsWith('#')) { continue }
        if ($t -match "'(legacy|mooc2|coursetree)'") {
            $hits += ('{0}:{1}  {2}' -f $f.Name, $n, $t)
        }
    }
}
foreach ($h in $hits) { Write-Host ('     ' + $h) -ForegroundColor DarkGray }
Write-Host ('   共 ' + @($hits).Count + ' 处') -ForegroundColor DarkGray
Write-Host ''

# ---- 4) 任务点类型支持情况 ----
Write-Host '4) 任务点类型支持：' -ForegroundColor Gray
$videoSrc = [System.IO.File]::ReadAllText((Join-Path $root 'lib\Video.psm1'), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('     视频      : ' + $(if ($videoSrc -match 'ans-job-video|VideoFramePattern') { '支持（自动播完）' } else { '不支持' })) -ForegroundColor DarkGray
Write-Host ('     PPT/PDF   : ' + $(if ($videoSrc -match 'pdf') { '部分' } else { '不支持（需手动翻到底并确认）' })) -ForegroundColor DarkGray
Write-Host ('     其它类型  : 不支持（会如实说明并停下）') -ForegroundColor DarkGray
Write-Host ''

# ---- 5) 测试覆盖 ----
Write-Host '5) 测试覆盖的页面结构：' -ForegroundColor Gray
foreach ($fx in (Get-ChildItem (Join-Path $root 'tests\fixture') -Filter *.html -File)) {
    Write-Host ('     ' + $fx.Name) -ForegroundColor DarkGray
}
Write-Host ''
Write-Host '（上面显示的夹具就是"通用路径"验证过的全部结构，数量有限。）' -ForegroundColor DarkGray
