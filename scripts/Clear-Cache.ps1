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
    Clear-Cache.bat
    询问后清理缓存目录。

.EXAMPLE
    Clear-Cache.bat -All
    连整个 browser-profile 一起删除。
#>

[CmdletBinding()]
param(
    [switch]$All,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$toolRoot = Split-Path -Parent $PSScriptRoot
$profileDir = Join-Path $toolRoot 'browser-profile'

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor DarkCyan
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor DarkCyan
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
    Write-Host '  还没有缓存目录，无需清理。' -ForegroundColor Green
    Write-Host ''
    exit 0
}

$before = Get-Size -Path $profileDir
Write-Host ('  目录: ' + $profileDir)
Write-Host ('  占用: ' + (Format-Size -Bytes $before))
Write-Host ''

if ($All) {
    Write-Host '  模式: 删除整个配置目录' -ForegroundColor Yellow
} else {
    Write-Host '  模式: 只清缓存（保留浏览器配置）' -ForegroundColor Yellow
}

if (-not $Yes) {
    Write-Host ''
    Write-Host '  开始清理？[y/N] ' -ForegroundColor White -NoNewline
    $ans = Read-Host
    if ($ans -notmatch '^(?i)y(es)?$') {
        Write-Host '  已取消。' -ForegroundColor Gray
        Write-Host ''
        exit 0
    }
}

# ---------------- 关闭工具专用浏览器 ----------------
Write-Host ''
Write-Host '  正在关闭工具专用的浏览器实例……' -ForegroundColor Gray

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
    Write-Host ('    已关闭 ' + $killed + ' 个进程') -ForegroundColor Gray
    Start-Sleep -Seconds 4          # 等文件句柄释放
} else {
    Write-Host '    没有正在运行的工具浏览器实例' -ForegroundColor Gray
}

# ---------------- 删除 ----------------
if ($All) {
    try {
        Remove-Item $profileDir -Recurse -Force -ErrorAction Stop
    } catch {
        Write-Host ''
        Write-Host ('  删除失败: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host '  请确认浏览器窗口已全部关闭，然后重试。' -ForegroundColor Yellow
        Write-Host ''
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
            Write-Host ('    已清 ' + $d + '（' + (Format-Size -Bytes $sz) + '）') -ForegroundColor Gray
        } catch {
            Write-Host ('    跳过 ' + $d + '（被占用）') -ForegroundColor Yellow
        }
    }
}

# ---------------- 结果 ----------------
$after = Get-Size -Path $profileDir
$freed = $before - $after

Write-Head '清理完成'
Write-Host ('  释放空间: ' + (Format-Size -Bytes $freed)) -ForegroundColor Green
Write-Host ('  当前占用: ' + (Format-Size -Bytes $after))
if (-not (Test-Path $profileDir)) {
    Write-Host '  配置目录已删除。' -ForegroundColor Green
}
if ($after -gt 0 -and -not $All) {
    Write-Host '  （剩下的是浏览器自身的配置数据，不是缓存）' -ForegroundColor DarkGray
}
Write-Host ''
