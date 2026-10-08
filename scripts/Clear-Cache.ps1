<#
.SYNOPSIS
    清理浏览器缓存。

.DESCRIPTION
    工具运行时会在 browser-profile 目录里累积浏览器数据。用久了可达数百 MB，
    其中绝大部分是 Edge 自己的网页缓存与组件包（视频片段、AI 数据等），
    与本工具无关。本脚本把这些缓存删掉，回收磁盘空间。

    脚本会先关闭工具专用的浏览器实例再删除 —— 目录被进程占用时删不干净，
    而且 Edge 会重建一半，留下更乱的状态。只关用本目录启动的进程，
    不会影响你日常使用的浏览器。

.PARAMETER All
    连配置目录一起删除（含浏览器自身的配置）。
    不加此参数时只删缓存类目录。

.PARAMETER Yes
    跳过确认，直接执行。

.EXAMPLE
    ClearCache.bat
    询问后清理缓存目录。

.EXAMPLE
    ClearCache.bat -All
    连整个 browser-profile 一起删除。
#>

[CmdletBinding()]
param(
    [switch]$All,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
# 无控制台时设置编码会抛"句柄无效"（重定向输出时会出现），
# 所以只在真有控制台时才设。控制台里的中文显示依赖这一步。
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

$toolRoot = Split-Path -Parent $PSScriptRoot
$profileDir = Join-Path $toolRoot 'browser-profile'


# 控制台输出出口。
# 统一走这里，便于集中控制输出方式。
function Write-Screen {
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Text,
        [string]$Tone = 'Gray',
        [switch]$NoNewline
    )
    if ($NoNewline) { Write-Host $Text -ForegroundColor $Tone -NoNewline }
    else { Write-Host $Text -ForegroundColor $Tone }
}

function Write-Head {
    param([string]$Text)
    Write-Screen -Text ''
    Write-Screen -Text ('=' * 60) -Tone DarkCyan
    Write-Screen -Text ('  ' + $Text) -Tone Cyan
    Write-Screen -Text ('=' * 60) -Tone DarkCyan
}

function Get-Size {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0.0 }
    $s = (Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if ($null -eq $s) { return 0.0 }
    return [double]$s
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1MB) { return ([math]::Round($Bytes / 1MB, 1)).ToString() + ' MB' }
    if ($Bytes -ge 1KB) { return ([math]::Round($Bytes / 1KB, 1)).ToString() + ' KB' }
    return ([int]$Bytes).ToString() + ' B'
}

Write-Head '清理浏览器缓存'

if (-not (Test-Path $profileDir)) {
    Write-Screen -Text '  还没有缓存目录，无需清理。' -Tone Green
    Write-Screen -Text ''
    exit 0
}

$before = Get-Size -Path $profileDir
Write-Screen -Text ('  目录: ' + $profileDir)
Write-Screen -Text ('  占用: ' + (Format-Size -Bytes $before))
Write-Screen -Text ''
if ($All) {
    Write-Screen -Text '  模式: 删除整个配置目录' -Tone Yellow
} else {
    Write-Screen -Text '  模式: 只清缓存（保留浏览器配置）' -Tone Yellow
}

if (-not $Yes) {
    Write-Screen -Text ''
    Write-Screen -Text '  开始清理？[y/N] ' -Tone White -NoNewline
    $ans = Read-Host
    if ($ans -notmatch '^(?i)y(es)?$') {
        Write-Screen -Text '  已取消。' -Tone Gray
        Write-Screen -Text ''
        exit 0
    }
}

# ---------------- 关闭工具专用浏览器 ----------------
Write-Screen -Text ''
Write-Screen -Text '  正在关闭工具专用的浏览器实例……' -Tone Gray

$killed = 0
try {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like "*$profileDir*" })
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $killed++
        } catch { }
    }
} catch { }

if ($killed -gt 0) {
    Write-Screen -Text ('    已关闭 ' + $killed + ' 个进程') -Tone Gray
    Start-Sleep -Seconds 4          # 等文件句柄释放
} else {
    Write-Screen -Text '    没有正在运行的工具浏览器实例' -Tone Gray
}

# ---------------- 删除 ----------------
if ($All) {
    try {
        Remove-Item $profileDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Screen -Text ''
        Write-Screen -Text ('  删除失败: ' + $_.Exception.Message) -Tone Red
        Write-Screen -Text '  请确认浏览器窗口已全部关闭，然后重试。' -Tone Yellow
        Write-Screen -Text ''
        exit 1
    }
} else {
    # 缓存类目录：体积大户，删掉不影响配置
    $cacheDirs = @(
        'Default\Cache', 'Default\Code Cache', 'Default\GPUCache',
        'Default\DawnGraphiteCache', 'Default\DawnWebGPUCache',
        'Default\Service Worker', 'Default\Application Cache',
        'GrShaderCache', 'ShaderCache', 'BrowserMetrics', 'BrowserMetrics-spare',
        'ProvenanceData', 'component_crx_cache',
        'Edge Entity Extraction', 'Edge Wallet', 'Edge Shopping',
        'Subresource Filter', 'Safe Browsing'
    )
    foreach ($d in $cacheDirs) {
        $p = Join-Path $profileDir $d
        if (-not (Test-Path $p)) { continue }
        $sz = Get-Size -Path $p
        try {
            Remove-Item $p -Recurse -Force -ErrorAction Stop
            Write-Screen -Text ('    已清 ' + $d + '（' + (Format-Size -Bytes $sz) + '）') -Tone Gray
        } catch {
            Write-Screen -Text ('    跳过 ' + $d + '（被占用）') -Tone Yellow
        }
    }
}

# ---------------- 结果 ----------------
$after = Get-Size -Path $profileDir
$freed = $before - $after

Write-Head '清理完成'
Write-Screen -Text ('  释放空间: ' + (Format-Size -Bytes $freed)) -Tone Green
Write-Screen -Text ('  当前占用: ' + (Format-Size -Bytes $after))
if (-not (Test-Path $profileDir)) {
    Write-Screen -Text '  配置目录已删除。' -Tone Green
}
if ($after -gt 0 -and -not $All) {
    Write-Screen -Text '  （剩下的是浏览器自身的配置数据，不是缓存）' -Tone DarkGray
}
Write-Screen -Text ''