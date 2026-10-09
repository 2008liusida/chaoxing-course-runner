<#
.SYNOPSIS
    回归测试：Get-JobStates 必须返回"每个任务点一个元素"，不能被展平。

.DESCRIPTION
    这个坑在本项目出现过多次：把 JSON 数组用
        @($r.Value | ConvertFrom-Json)
    包一层，会得到"一个元素，里面是整个数组" ——
    于是 Count 变成 1、各属性变成数组（打印出来是 "True False" 这种）。

    后果很隐蔽：多视频、多任务点的判断全部按 1 个来算，
    表现为"明明有两个视频却只认一个""反复重播第一个视频"。
    编译期查不出来，只有真跑才暴露，所以要有回归测试盯着。

    这里直接对实现做静态检查（不依赖浏览器）：
      · 不允许出现 @(... | ConvertFrom-Json) 这种写法
      · 每个解析 JSON 数组的函数都要"先赋值再判断是不是数组"
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$ok = 0; $fail = 0
function Check {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    if ($Pass) { Write-Host ('  [OK]   ' + $Name) -ForegroundColor Green; $script:ok++ }
    else {
        Write-Host ('  [FAIL] ' + $Name + $(if ($Detail) { ' -> ' + $Detail } else { '' })) -ForegroundColor Red
        $script:fail++
    }
}

Write-Host '=== JSON 数组解析回归测试 ===' -ForegroundColor Cyan
Write-Host ''

# 扫描所有 .psm1 / .ps1：找出 @(... | ConvertFrom-Json) 这种写法
$bad = @()
foreach ($f in (Get-ChildItem $root -Recurse -Include *.psm1, *.ps1 -File |
        Where-Object { $_.FullName -notmatch '\\(\.git|tests\\fixture)\\' })) {
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, (New-Object System.Text.UTF8Encoding($false)))) {
        $n++
        # 只查代码行。
        # 注释、以及测试脚本里"作为反面教材写出来"的字样不算违规 ——
        # 一开始没排除，报了一堆误报，反而淹没了真问题。
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith('#')) { continue }
        if ($trimmed.StartsWith('·') -or $trimmed.StartsWith('-')) { continue }
        # 跳过测试脚本自身与专门解释这个坑的文件
        if ($f.Name -in @('json-array.ps1', 'check-jsonarray.ps1')) { continue }
        # 只认"真正把它当语句用"的形态：赋值或返回
        if ($trimmed -match '(=|return)\s*@\([^)]*\|\s*ConvertFrom-Json') {
            $bad += ($f.Name + ':' + $n + '  ' + $trimmed)
        }
    }
}
Check '没有 @(... | ConvertFrom-Json) 的写法' ($bad.Count -eq 0) ($bad -join ' | ')

# Get-JobStates 必须"先赋值再判断"
$videoPath = Join-Path $root 'lib\Video.psm1'
$videoSrc = [System.IO.File]::ReadAllText($videoPath, (New-Object System.Text.UTF8Encoding($false)))
Check 'Get-JobStates 用"先赋值再判断"' ($videoSrc -match 'if \(\$parsed -is \[array\]\)')
Check 'Get-JobStates 只用"明确已完成"判完成' ($videoSrc -match "lb === '任务点已完成'")

# Get-ChapterTree 同样处理
$chaoxingPath = Join-Path $root 'lib\Chaoxing.psm1'
$chaoxingSrc = [System.IO.File]::ReadAllText($chaoxingPath, (New-Object System.Text.UTF8Encoding($false)))
Check 'Get-ChapterTree 用"先赋值再判断"' ($chaoxingSrc -match '\$raw = if \(\$parsed -is \[array\]\)')

# CdpClient 的目标列表
$cdpPath = Join-Path $root 'lib\CdpClient.psm1'
$cdpSrc = [System.IO.File]::ReadAllText($cdpPath, (New-Object System.Text.UTF8Encoding($false)))
Check 'Get-CdpTargets 先赋值再返回' ($cdpSrc -match '(?s)function Get-CdpTargets.*?return \$targets')

# 视频选择必须按帧 id（帧 id 稳定，上下文 id 每次枚举都变）
Check 'Get-VideoFrames 存在（提供稳定帧 id）' ($cdpSrc -match 'function Get-VideoFrames')
Check 'Get-FrameContextById 存在' ($cdpSrc -match 'function Get-FrameContextById')
Check 'Select-NextVideoContext 按帧 id 排除' ($videoSrc -match '\$ExcludeFrameIds')
# 判据在实现里改过两次：
#   最初按"帧数与任务点数配对"跳过 -> 实测 2.4 节 1 帧 2 任务点被误判，
#   现在改成只有"数量能一一对上"且该位明确标注已完成时才跳过。
Check 'Select-NextVideoContext 只在对得上时跳过已完成' `
    ($videoSrc -match 'if \(\$pairedByCount -and \$states\[\$i\]\.Finished\) \{ \$skippedDone\+\+; continue \}')
Check 'Select-NextVideoContext 不把配对当门禁' ($videoSrc -match '\$pairedByCount = \(\$states\.Count -eq \$frames\.Count\)')

Write-Host ''
if ($fail -eq 0) {
    Write-Host ('===== JSON 解析回归测试: 通过 ' + $ok + ' 项 =====') -ForegroundColor Green
    exit 0
} else {
    Write-Host ('===== JSON 解析回归测试: 通过 ' + $ok + ' 项，失败 ' + $fail + ' 项 =====') -ForegroundColor Red
    exit 1
}
