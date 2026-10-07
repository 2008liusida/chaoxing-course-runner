<#
.SYNOPSIS
    环境自检：跑不起来时用来定位问题。

.DESCRIPTION
    只读检查，不修改任何东西。覆盖换机器后最常见的失败原因：
      · 文件是否被 Windows「阻止」（从网上下载的 zip 会带 Zone.Identifier，
        解压后 .ps1 会因安全策略拒绝执行）
      · 解压是否完整（少文件是最常见的原因）
      · PowerShell 版本与执行策略
      · 浏览器是否存在、调试端口能否启动
      · 学习通登录态配置文件是否存在
      · 中文与编码是否正常

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\diagnose-env.ps1
#>

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Split-Path -Parent $PSScriptRoot

function Section($t) {
    Write-Output ''
    Write-Output ('===== ' + $t + ' =====')
}
function Ok($m) { Write-Output ('  [OK]   ' + $m) }
function Warn($m) { Write-Output ('  [警告] ' + $m) }
function Bad($m) { Write-Output ('  [问题] ' + $m) }
function Info($m) { Write-Output ('         ' + $m) }

Write-Output 'ChaoxingCourseRunner 环境自检'
Write-Output ('时间: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
Write-Output ('工具目录: ' + $root)

# ---------------- 1. 文件完整性 ----------------
Section '1. 文件完整性'
$required = @(
    'Run.ps1'
    'Start.bat'
    'first-run-login.bat'
    'config.psd1'
    'lib\ChaoxingCourseRunner.psd1'
    'lib\CdpClient.psm1'
    'lib\Chaoxing.psm1'
    'lib\Video.psm1'
    'lib\Settings.psm1'
    'lib\Selectors.psd1'
    'lib\Selectors.psm1'
    'lib\Logging.psm1'
    'lib\Browser.psm1'
)
$missing = @()
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $root $f))) { $missing += $f }
}
if ($missing.Count -eq 0) {
    Ok ('必需文件齐全（' + $required.Count + ' 个）')
} else {
    Bad ('缺少 ' + $missing.Count + ' 个文件 —— 解压不完整，请重新完整解压')
    foreach ($m in $missing) { Info $m }
}

$total = @(Get-ChildItem $root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notlike '*\.git\*' }).Count
Info ('目录内文件总数: ' + $total)

# ---------------- 2. 文件是否被阻止 ----------------
Section '2. 文件是否被 Windows 阻止'
# 从网上下载的 zip 解压后，每个文件会带 Zone.Identifier 备用数据流，
# PowerShell 会因此拒绝执行脚本（常表现为窗口一闪就没）。
$blocked = @()
foreach ($f in (Get-ChildItem $root -Recurse -Include *.ps1, *.psm1, *.psd1, *.bat -File -ErrorAction SilentlyContinue)) {
    try {
        $z = Get-Item -Path $f.FullName -Stream Zone.Identifier -ErrorAction Stop
        if ($z) { $blocked += $f.FullName.Replace($root + '\', '') }
    } catch { }
}
if ($blocked.Count -eq 0) {
    Ok '没有被阻止的文件'
} else {
    Bad ('有 ' + $blocked.Count + ' 个文件被 Windows 标记为"来自网络"，脚本会被拒绝执行')
    foreach ($b in ($blocked | Select-Object -First 8)) { Info $b }
    if ($blocked.Count -gt 8) { Info ('... 另外 ' + ($blocked.Count - 8) + ' 个') }
    Write-Output ''
    Info '解决办法（任选其一）：'
    Info '  A. 右键 zip 文件 -> 属性 -> 勾选"解除锁定" -> 确定，然后重新解压'
    Info '  B. 或在 PowerShell 里执行（对本目录一次性解除）：'
    Info ('     Get-ChildItem -Path "' + $root + '" -Recurse | Unblock-File')
}

# ---------------- 3. PowerShell 环境 ----------------
Section '3. PowerShell 环境'
Info ('PowerShell 版本: ' + $PSVersionTable.PSVersion.ToString())
Info ('宿主: ' + (Get-Process -Id $PID).ProcessName)
$pol = Get-ExecutionPolicy
Info ('生效执行策略: ' + $pol)
if ($pol -in @('Restricted', 'AllSigned')) {
    Warn '执行策略较严，直接跑 .ps1 可能被拒。用 Start.bat 启动（脚本内已加 -ExecutionPolicy Bypass）'
} else {
    Ok '执行策略不阻碍运行'
}
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Info ('当前是否管理员: ' + $isAdmin + '（不需要管理员权限）')

# ---------------- 4. 浏览器 ----------------
Section '4. 浏览器'
$edgePaths = @(
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
)
$chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$foundEdge = @($edgePaths | Where-Object { $_ -and (Test-Path $_) })
$foundChrome = @($chromePaths | Where-Object { $_ -and (Test-Path $_) })
if ($foundEdge.Count -gt 0) { Ok ('Edge: ' + $foundEdge[0]) } else { Warn '未找到 Edge' }
if ($foundChrome.Count -gt 0) { Ok ('Chrome: ' + $foundChrome[0]) } else { Info '未找到 Chrome（有 Edge 即可）' }
if ($foundEdge.Count -eq 0 -and $foundChrome.Count -eq 0) {
    Bad '既没有 Edge 也没有 Chrome，工具无法工作'
}

$running = @(Get-Process msedge, chrome -ErrorAction SilentlyContinue).Count
Info ('当前正在运行的浏览器进程数: ' + $running + '（不影响使用）')

# 探测调试端口可用性
$port = 9222
$cfgPath = Join-Path $root 'config.psd1'
if (Test-Path $cfgPath) {
    $m = Select-String -Path $cfgPath -Pattern '^\s*\$DebugPort\s*=\s*(\d+)' -ErrorAction SilentlyContinue
    if ($m) { $port = [int]$m.Matches[0].Groups[1].Value }
}
$portOk = $false
try {
    $v = Invoke-RestMethod -Uri ("http://127.0.0.1:${port}/json/version") -TimeoutSec 3
    $portOk = $true
    Ok ('调试端口 ' + $port + ' 已有实例: ' + $v.Browser)
} catch {
    Info ('调试端口 ' + $port + ' 当前无实例（正常，工具会自动启动一个）')
}
$portUsed = @(netstat -ano -ErrorAction SilentlyContinue | Select-String (':' + $port + '\s'))
if ($portUsed.Count -gt 0 -and -not $portOk) {
    Warn ('端口 ' + $port + ' 被其它程序占用，请在 config.psd1 里换一个（如 9223）')
}

# ---------------- 5. 登录态 ----------------
Section '5. 学习通登录态'
$profileDir = Join-Path $root 'browser-profile'
if (Test-Path $profileDir) {
    $size = (Get-ChildItem $profileDir -Recurse -File -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum
    Ok ('已存在浏览器配置目录（' + [math]::Round($size / 1MB, 1) + ' MB）—— 若登录过期，删掉它重跑 first-run-login.bat')
} else {
    Info '还没有浏览器配置目录 —— 属于首次使用，请先跑 first-run-login.bat 登录'
}

# ---------------- 6. 编码与中文 ----------------
Section '6. 编码与中文'
Info ('控制台代码页: ' + ([Console]::OutputEncoding.WebName))
$cnTest = '中文测试：如果你能看到这行完整中文，编码正常'
Write-Output ('  ' + $cnTest)
$bomMissing = @()
foreach ($f in (Get-ChildItem $root -Recurse -Include *.ps1, *.psm1, *.psd1 -File -ErrorAction SilentlyContinue)) {
    $b = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if (-not $hasBom) { $bomMissing += $f.Name }
}
if ($bomMissing.Count -eq 0) {
    Ok '所有脚本带 UTF-8 BOM（PowerShell 5.1 正确读中文的前提）'
} else {
    Bad ('有 ' + $bomMissing.Count + ' 个脚本缺少 UTF-8 BOM，5.1 下会读成乱码并报语法错误')
    foreach ($b in $bomMissing) { Info $b }
}

# ---------------- 7. 模块能否加载 ----------------
Section '7. 模块加载与选择器'
try {
    Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking -ErrorAction Stop
    $cmds = @(Get-Command -Module ChaoxingCourseRunner | Select-Object -ExpandProperty Name)
    Ok ('模块加载成功，导出 ' + $cmds.Count + ' 个函数')
    $sel = Import-CourseSelectors
    Ok ('选择器解析成功: LessonNode=' + $sel.LessonNode + ' UnfinishedMark=' + $sel.UnfinishedMark)
} catch {
    Bad ('模块加载失败: ' + $_.Exception.Message)
    Info '常见原因：文件缺失、缺 BOM、或被 Windows 阻止（见第 1、2 节）'
}

# ---------------- 8. 日志 ----------------
Section '8. 上次运行的日志'
$logPath = Join-Path $root 'logs\run.log'
if (Test-Path $logPath) {
    $last = Get-Item $logPath
    Ok ('存在日志: ' + $last.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') + '（' + [math]::Round($last.Length / 1KB, 1) + ' KB）')
    Write-Output '         最后 5 行：'
    Get-Content $logPath -Encoding UTF8 -Tail 5 | ForEach-Object { Info $_ }
} else {
    Info '还没有日志 —— 说明 Run.ps1 还没成功跑过一次'
}

Write-Output ''
Write-Output '===== 自检结束 ====='
Write-Output ('自检完成。详细日志: ' + (Join-Path $root 'logs\run.log'))
