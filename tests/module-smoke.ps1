<#
.SYNOPSIS
    模块冒烟测试：导出清单、选择器解析、配置校验。

.DESCRIPTION
    不需要浏览器，可在任意机器上直接运行。
    所有路径均相对本脚本位置推导（$PSScriptRoot），不依赖当前工作目录，
    也不含任何硬编码的绝对路径 —— 这样换机器 / 换目录拷贝后仍能直接跑。

    覆盖：
      1. 模块能加载，且导出函数数量与清单一致
      2. 选择器表能解析，关键键存在且取值正确
      3. 配置文件能读，键名与类型转换正确
      4. 两条报错路径确实会报错（缺键的选择器、非法配置值）

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\module-smoke.ps1
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# 仓库根目录 = 本脚本所在目录的上一级
$root = Split-Path -Parent $PSScriptRoot

$script:Pass = 0
$script:Fail = 0
$tempFiles = New-Object System.Collections.Generic.List[string]

function Assert-Equal {
    param([string]$Name, $Actual, $Expected)
    if ("$Actual" -eq "$Expected") {
        $script:Pass++
        Write-Output ("  [OK]   {0} = {1}" -f $Name, $Actual)
    } else {
        $script:Fail++
        Write-Output ("  [FAIL] {0}: 实际={1} 期望={2}" -f $Name, $Actual, $Expected)
    }
}

function Assert-True {
    param([string]$Name, $Condition, [string]$Detail = '')
    if ($Condition) {
        $script:Pass++
        Write-Output ("  [OK]   {0}{1}" -f $Name, $(if ($Detail) { " -> $Detail" } else { '' }))
    } else {
        $script:Fail++
        Write-Output ("  [FAIL] {0}{1}" -f $Name, $(if ($Detail) { " -> $Detail" } else { '' }))
    }
}

try {
    # ---------------- 1. 模块加载与导出 ----------------
    Write-Output '--- 1. 模块加载与导出 ---'
    $manifestPath = Join-Path $root 'lib\ChaoxingCourseRunner.psd1'
    Assert-True '库清单存在' (Test-Path $manifestPath) $manifestPath
    if (-not (Test-Path $manifestPath)) { throw '库清单不存在，无法继续' }

    Import-Module $manifestPath -Force -DisableNameChecking

    $cmds = @(Get-Command -Module ChaoxingCourseRunner | Select-Object -ExpandProperty Name | Sort-Object)
    Assert-True '导出函数数量 > 0' ($cmds.Count -gt 0) ("共 " + $cmds.Count + " 个")
    # 关键函数必须在
    foreach ($fn in @('Get-LessonList', 'Get-VideoState', 'Switch-Lesson', 'Get-RunnerSettings',
                      'Import-CourseSelectors', 'Get-BrowserWindowHandle', 'Resolve-Platform',
                      'Invoke-Lesson', 'Enable-LessonVideoPlayback')) {
        Assert-True ("导出包含 " + $fn) ($cmds -contains $fn)
    }

    # ---------------- 2. 选择器表（按平台版本分组）----------------
    Write-Output ''
    Write-Output '--- 2. 选择器表解析（legacy / mooc2 / common）---'
    $raw = Import-CourseSelectors
    foreach ($block in @('common', 'legacy', 'mooc2')) {
        Assert-True ("存在区块 " + $block) ($raw.ContainsKey($block))
    }

    # legacy 版
    Assert-Equal 'legacy.LessonNode'      $raw.legacy.LessonNode      'h5[id^=cur]'
    Assert-Equal 'legacy.UnfinishedMark'  $raw.legacy.UnfinishedMark  'orange'
    Assert-Equal 'legacy.CurrentLessonId' $raw.legacy.CurrentLessonId '#curChapterId'
    Assert-Equal 'legacy.UnfinishedBy'    $raw.legacy.UnfinishedBy    'state-dot'

    # mooc2 版
    Assert-Equal 'mooc2.LessonNode'       $raw.mooc2.LessonNode       'div.posCatalog_select'
    Assert-Equal 'mooc2.ActiveMark'       $raw.mooc2.ActiveMark       'posCatalog_active'
    Assert-Equal 'mooc2.ChapterOnlyMark'  $raw.mooc2.ChapterOnlyMark  'firstLayer'
    Assert-Equal 'mooc2.UnfinishedCount'  $raw.mooc2.UnfinishedCount  'input.jobUnfinishCount'
    Assert-Equal 'mooc2.UnfinishedBy'     $raw.mooc2.UnfinishedBy     'job-count'
    Assert-True  'mooc2 目录在 iframe 内' ([bool]$raw.mooc2.DirectoryInFrame)

    # 共用部分
    Assert-True 'common.PageFingerprints 非空' (@($raw.common.PageFingerprints).Count -gt 0) ((@($raw.common.PageFingerprints)) -join ' | ')
    Assert-Equal 'common.SwitchFunction' $raw.common.SwitchFunction 'getTeacherAjax'

    # 合并逻辑
    $flat = Merge-SelectorTable -Raw $raw -VersionName 'mooc2'
    Assert-Equal '合并后 Version' $flat.Version 'mooc2'
    Assert-Equal '合并后取到版本键' $flat.LessonNode 'div.posCatalog_select'
    Assert-Equal '合并后取到 common 键' $flat.SwitchFunction 'getTeacherAjax'
    $flatLegacy = Merge-SelectorTable -Raw $raw -VersionName 'legacy'
    Assert-Equal 'legacy 合并后 LessonNode' $flatLegacy.LessonNode 'h5[id^=cur]'

    # ---------------- 3. 配置读取 ----------------
    Write-Output ''
    Write-Output '--- 3. 配置读取与类型转换 ---'
    $cfgPath = Join-Path $root 'config.psd1'
    Assert-True '配置文件存在' (Test-Path $cfgPath) $cfgPath
    $cfg = Get-RunnerSettings -ConfigPath $cfgPath
    Assert-True 'DebugPort 是整数' ($cfg.DebugPort -is [int]) ("DebugPort=" + $cfg.DebugPort)
    Assert-True 'PlaybackRate 是数字' ($cfg.PlaybackRate -is [double]) ("PlaybackRate=" + $cfg.PlaybackRate)
    Assert-True 'KeepForeground 是布尔' ($cfg.KeepForeground -is [bool]) ("KeepForeground=" + $cfg.KeepForeground)
    Assert-True 'SwitchMode 取值合法' ($cfg.SwitchMode -in @('auto', 'click')) ("SwitchMode=" + $cfg.SwitchMode)
    # 相对路径应被解析成"工具根目录下"的绝对路径，而不是当前工作目录
    Assert-True 'ProfileDir 已解析为绝对路径' ([System.IO.Path]::IsPathRooted($cfg.ProfileDir)) $cfg.ProfileDir
    Assert-True 'LogFile 已解析为绝对路径' ([System.IO.Path]::IsPathRooted($cfg.LogFile)) $cfg.LogFile
    Assert-True 'ProfileDir 位于仓库内' ($cfg.ProfileDir.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) $cfg.ProfileDir

    # ---------------- 4. 报错路径 ----------------
    Write-Output ''
    Write-Output '--- 4. 应当报错的路径 ---'

    $badSel = Join-Path $env:TEMP ('bad-selectors-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
    $tempFiles.Add($badSel)
    Set-Content -Path $badSel -Value "@{`n  LessonNode = 'x'`n}" -Encoding UTF8
    $threw = $false
    try { [void](Import-CourseSelectors -Path $badSel) } catch { $threw = $true }
    Assert-True '缺键的选择器应报错' $threw

    $badCfg = Join-Path $env:TEMP ('bad-config-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.psd1')
    $tempFiles.Add($badCfg)
    Set-Content -Path $badCfg -Value "`$SwitchMode = 'bogus'" -Encoding UTF8
    $threw2 = $false
    try { [void](Get-RunnerSettings -ConfigPath $badCfg) } catch { $threw2 = $true }
    Assert-True '非法 SwitchMode 应报错' $threw2

    # ---------------- 5. JSON 数组兼容 ----------------
    Write-Output ''
    Write-Output '--- 5. JSON 数组解析（5.1/7.x 兼容）---'
    $arr = ConvertFrom-JsonArray -Json '[{"Id":"1","U":true},{"Id":"2","U":false}]'
    Assert-Equal '数组元素个数' (@($arr).Count) 2
    Assert-Equal '首元素可读属性' (@($arr)[0].Id) '1'
    Assert-Equal '空字符串输入' (@(ConvertFrom-JsonArray -Json '').Count) 0
    Assert-Equal '单对象输入' (@(ConvertFrom-JsonArray -Json '{"a":1}').Count) 1
} finally {
    foreach ($f in $tempFiles) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}


# ---------------- P/Invoke 声明与调用一致性 ----------------
# 目的：拦住"调用了未声明的 Win32 方法"这类问题。
# 这种错误会被 try/catch 吞掉，表现为静默退化为默认值 ——
# 功能看起来正常，实际没生效，极难排查（本次开发中真实踩到过）。
$win32Files = @(
    (Join-Path $root 'lib\PageVisibility.psm1'),
    (Join-Path $root 'lib\Browser.psm1')
)
$declMissing = @()
foreach ($wf in $win32Files) {
    if (-not (Test-Path $wf)) { continue }
    $wc = [System.IO.File]::ReadAllText($wf, (New-Object System.Text.UTF8Encoding($false)))
    $declared = @{}
    foreach ($m in [regex]::Matches($wc, 'public static extern [\w\.]+ (\w+)\s*\(')) {
        $declared[$m.Groups[1].Value] = $true
    }
    # 匹配本项目自己的 P/Invoke 类：形如 [Ccr.Xxx]::Method 或 [CcrVis.Win]::Method。
    # 不能用更宽的 [任意类]::方法 —— 那会把 [IntPtr]::Zero、[math]::Abs 也算进来。
    # 也不能限定单一类名 —— 之前限定过 CcrVis|Ccr|NativeMethods 的固定组合，
    # 结果漏掉了误写成别的类的调用。
    foreach ($m in [regex]::Matches($wc, '\[Ccr[\w\.]*\]::(\w+)')) {
        $name = $m.Groups[1].Value
        if (-not $declared.ContainsKey($name)) {
            $declMissing += ((Split-Path $wf -Leaf) + ':' + $name)
        }
    }
}
Assert-True 'Win32 方法调用均有声明（缺失会静默失败）' ($declMissing.Count -eq 0)
if ($declMissing.Count -gt 0) {
    Write-Host ('      缺失: ' + ($declMissing -join ', ')) -ForegroundColor Red
}



# ---------------- 导出清单完整性 ----------------
# 只数数量不够 —— 清单里可能有"幽灵导出"（写了名字但没有对应函数定义），
# 调用时才报 CommandNotFound。这里逐个核对定义是否存在。
$manifestPath = Join-Path $root 'lib\ChaoxingCourseRunner.psd1'
$manText = [System.IO.File]::ReadAllText($manifestPath, (New-Object System.Text.UTF8Encoding($false)))
$exportedNames = @()
foreach ($m in [regex]::Matches($manText, "'([A-Z][\w-]+)'")) {
    $exportedNames += $m.Groups[1].Value
}
$definedFns = @{}
foreach ($mf in @(Get-ChildItem (Join-Path $root 'lib') -Filter '*.psm1' -File)) {
    $mc = [System.IO.File]::ReadAllText($mf.FullName, (New-Object System.Text.UTF8Encoding($false)))
    foreach ($m in [regex]::Matches($mc, '(?m)^\s*function\s+([A-Z][\w-]+)')) {
        $definedFns[$m.Groups[1].Value] = $true
    }
}
$ghosts = @($exportedNames | Where-Object { -not $definedFns.ContainsKey($_) })
Assert-True '导出清单里的函数都有定义（无幽灵导出）' ($ghosts.Count -eq 0)
if ($ghosts.Count -gt 0) {
    Write-Host ('      幽灵导出: ' + ($ghosts -join ', ')) -ForegroundColor Red
}
Assert-True '导出函数确实可调用' (@($exportedNames | Where-Object { $cmds -contains $_ }).Count -eq $exportedNames.Count)

# ---------------- Win32 函数与 DLL 归属 ----------------
# 声明了方法但写错 DLL，症状与"没声明"一样：调用抛异常、被 catch 吞掉、
# 功能静默退化。GetConsoleWindow 曾在 user32 与 kernel32 之间写错过。
$dllExpect = @{
    'GetConsoleWindow'         = 'kernel32.dll'
    'EnumWindows'              = 'user32.dll'
    'GetWindowRect'            = 'user32.dll'
    'SetWindowPos'             = 'user32.dll'
    'ShowWindow'               = 'user32.dll'
    'IsIconic'                 = 'user32.dll'
    'IsZoomed'                 = 'user32.dll'
    'IsWindowVisible'          = 'user32.dll'
    'SetForegroundWindow'      = 'user32.dll'
    'GetWindow'                = 'user32.dll'
    'IsWindow'                 = 'user32.dll'
    'GetWindowThreadProcessId' = 'user32.dll'
    'SystemParametersInfo'     = 'user32.dll'
    'DwmGetWindowAttribute'    = 'dwmapi.dll'
}
$dllWrong = @()
foreach ($wf in $win32Files) {
    if (-not (Test-Path $wf)) { continue }
    $wc = [System.IO.File]::ReadAllText($wf, (New-Object System.Text.UTF8Encoding($false)))
    foreach ($m in [regex]::Matches($wc, 'DllImport\("([\w\.]+)"\)\]\s*public static extern [\w\.]+ (\w+)\s*\(')) {
        $dll = $m.Groups[1].Value
        $fn = $m.Groups[2].Value
        if ($dllExpect.ContainsKey($fn) -and $dllExpect[$fn] -ne $dll) {
            $dllWrong += ($fn + ' 应在 ' + $dllExpect[$fn] + '，实为 ' + $dll)
        }
    }
}
Assert-True 'Win32 函数声明在正确的 DLL（写错会静默失败）' ($dllWrong.Count -eq 0)
if ($dllWrong.Count -gt 0) {
    Write-Host ('      ' + ($dllWrong -join '; ')) -ForegroundColor Red
}

# ---------------- 窗口布局相关函数 ----------------
foreach ($fn in @('Arrange-Windows', 'Set-WindowHalf', 'Get-WindowFrameInsets', 'Get-TerminalWindowHandle', 'Get-ScreenWorkArea')) {
    Assert-True ('已导出 ' + $fn) ($cmds -contains $fn)
}
$area = Get-ScreenWorkArea
Assert-True '能取到屏幕工作区' ($null -ne $area -and $area.Width -gt 0)
if ($area) {
    Assert-True '工作区宽度可二等分' (([int]($area.Width / 2)) * 2 -le $area.Width)
}

# ---------------- 汇总 ----------------
Write-Output ''
Write-Output ('===== 冒烟测试结果: 通过 ' + $script:Pass + ' 项，失败 ' + $script:Fail + ' 项 =====')
if ($script:Fail -gt 0) { exit 1 }
exit 0
