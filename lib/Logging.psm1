<#
    日志。

    设计取舍：不引入日志框架，保持零依赖。输出同时到控制台（带颜色）
    和文件（纯文本、UTF-8）。DEBUG 级别默认只写文件，避免刷屏。

    控制台只输出正文，不带时间戳与级别标签 —— 使用者看的是内容，
    前缀只是噪音；级别靠文字颜色区分。
    日志文件里保留完整的时间戳与级别（INFO/WARN/ERROR/OK），
    便于事后检索与工具处理。
#>

Set-StrictMode -Version Latest

$script:LevelRank = @{ DEBUG = 0; INFO = 1; WARN = 2; ERROR = 3; OK = 1 }

# 控制台级别标签 -> 中文显示
$script:LevelLabel = @{
    DEBUG = '调试'
    INFO  = '信息'
    WARN  = '警告'
    ERROR = '错误'
    OK    = '成功'
}

# 进度行状态。必须在模块加载时显式初始化 ——
# StrictMode 下读取未定义变量会抛 RuntimeException，
# 而 Write-RunnerLog 每次都要读它来判断"是否有进度行正在显示"。
$script:ProgressLineActive = $false

function Write-RunnerLog {
    <#
    .SYNOPSIS
        写一条日志到控制台和（可选的）文件。
    .PARAMETER Message
        日志正文。
    .PARAMETER Path
        日志文件路径。为空则只输出到控制台。
    .PARAMETER Level
        DEBUG / INFO / WARN / ERROR / OK。OK 只影响颜色，语义上等同于"成功"。
    .PARAMETER Transient
        临时行：输出到控制台但不写文件。
        用于播放进度这类高频刷新、无长期价值的信息 ——
        写进文件会把日志撑大，并淹没"完成 / 跳过 / 失败原因"等关键事件。
        文件里仍会周期性留下里程碑记录（由调用方决定何时记录）。
    .EXAMPLE
        Write-RunnerLog -Message '开始播放' -Path '.\logs\run.log' -Level INFO
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][string]$Path,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO',
        [switch]$Transient,
        [switch]$FileOnly
    )

    $now = Get-Date
    $stamp = $now.ToString('yyyy-MM-dd HH:mm:ss')
    $fileLine = "[$stamp] [$Level] $Message"

    $color = switch ($Level) {
        'WARN' { 'Yellow' }
        'ERROR' { 'Red' }
        'OK' { 'Green' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }

    # 控制台只输出正文：不带时间戳、不带级别标签。
    # 级别信息保留在日志文件里（fileLine），控制台靠颜色区分。
    $consoleLine = $Message

    # FileOnly：只落盘，不输出控制台。
    # 用于"里程碑"这类只需留档、不需打扰使用者的记录 ——
    # 输出到控制台会打断进度条的就地刷新，让进度条变成一行一行往下滚。
    if ($FileOnly) {
        if ($Path) {
            try {
                $dir = Split-Path -Parent $Path
                if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                Add-Content -Path $Path -Value $fileLine -Encoding UTF8
            } catch {
                Write-Host ('[警告] 无法写入日志文件 ' + $Path + ' : ' + $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        return
    }

    if ($Transient) {
        # 就地覆盖当前行（不清屏，保留上下文）。宽度自适应，避免折行。
        $width = 100
        try {
            $w = $Host.UI.RawUI.WindowSize.Width
            if ($w -gt 20) { $width = $w - 1 }
        } catch { }
        if ($consoleLine.Length -gt $width) {
            $consoleLine = $consoleLine.Substring(0, $width)
        } else {
            $pad = $width - $consoleLine.Length
            if ($pad -gt 0) { $consoleLine = $consoleLine + (' ' * $pad) }
        }
        Write-Host ("`r" + $consoleLine) -ForegroundColor $color -NoNewline
        return
    }

    # 非临时行：若上一行是就地刷新的进度行，先换行收尾，避免它被覆盖
    if ($script:ProgressLineActive) {
        Write-Host ''
        $script:ProgressLineActive = $false
    }
    Write-Host $consoleLine -ForegroundColor $color

    if ($Path) {
        try {
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Add-Content -Path $Path -Value $fileLine -Encoding UTF8
        } catch {
            # 日志落盘失败不应中断主流程，只在控制台提示一次
            Write-Host "[警告] 无法写入日志文件 $Path : $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Write-ProgressLine {
    <#
    .SYNOPSIS
        在控制台同一行内刷新进度（单条进度条）。
    .DESCRIPTION
        与 Write-RunnerLog -Transient 的区别：本函数总是不写文件，
        专用于"播放进度"这一类高频刷新。
        结束后请调用 Clear-ProgressLine 换行收尾。
    .PARAMETER Text
        要显示的文本。调用方负责把百分比、时长等拼好。
    .PARAMETER Color
        颜色。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text,
        [string]$Color = 'DarkCyan'
    )
    # 补位宽度按终端实际宽度自适应（留 1 字符余量）。
    # 写死宽度会在窄窗口里折行，进度条就变成一行一行往下滚 ——
    # 那就等于没有就地刷新。
    $width = 100
    try {
        $w = $Host.UI.RawUI.WindowSize.Width
        if ($w -gt 20) { $width = $w - 1 }
    } catch { }

    $line = $Text
    if ($line.Length -gt $width) {
        # 超宽则截断，宁可少显示也不要折行
        $line = $line.Substring(0, $width)
    } elseif ($line.Length -lt $width) {
        $line = $line + (' ' * ($width - $line.Length))
    }

    Write-Host ("`r" + $line) -ForegroundColor $Color -NoNewline
    $script:ProgressLineActive = $true
}

function Clear-ProgressLine {
    <#
    .SYNOPSIS
        结束就地刷新的进度行：换行并复位状态。
    #>
    [CmdletBinding()]
    param()
    if ($script:ProgressLineActive) {
        Write-Host ''
        $script:ProgressLineActive = $false
    }
}

Export-ModuleMember -Function Write-RunnerLog, Write-ProgressLine, Clear-ProgressLine
