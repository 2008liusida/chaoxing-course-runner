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

# 统一的控制台输出出口。
#
# 为什么需要它：图形界面版本把本工具跑在没有控制台的 runspace 里，
# 那里 Write-Host 会失败或产生乱码（颜色、光标控制都无处落脚）。
# 所以由这一个函数决定怎么输出：
#   · 控制台：带颜色直接打印
#   · 图形界面：走输出流，由界面捕获并按级别着色
function Write-ConsoleLine {
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Text,
        [string]$Level = 'Gray',
        [switch]$NoNewline
    )
    if ($env:CCR_GUI -eq '1') {
        # 交给管道的输出流；界面按内容判断级别并着色
        Write-Output $Text
        return
    }
    if ($NoNewline) {
        Write-Host $Text -ForegroundColor $Level -NoNewline
    } else {
        Write-Host $Text -ForegroundColor $Level
    }
}

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
    .EXAMPLE
        Write-RunnerLog -Message '开始播放' -Path '.\logs\run.log' -Level INFO
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][string]$Path,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO',
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
                Write-ConsoleLine -Text ('[警告] 无法写入日志文件 ' + $Path + ' : ' + $_.Exception.Message) -Level 'Yellow'
            }
        }
        return
    }


    # 非临时行：若上一行是就地刷新的进度行，先换行收尾，避免它被覆盖
    if ($script:ProgressLineActive) {
        Write-ConsoleLine -Text ''
        $script:ProgressLineActive = $false
    }
    Write-ConsoleLine -Text $consoleLine -Level $color

    if ($Path) {
        try {
            $dir = Split-Path -Parent $Path
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Add-Content -Path $Path -Value $fileLine -Encoding UTF8
        } catch {
            # 日志落盘失败不应中断主流程，只在控制台提示一次
            Write-ConsoleLine -Text ("[警告] 无法写入日志文件 " + $Path + " : " + $_.Exception.Message) -Level 'Yellow'
        }
    }
}

function Write-ProgressLine {
    <#
    .SYNOPSIS
        在控制台同一行内刷新进度（单条进度条）。
    .DESCRIPTION
        本函数总是不写文件，
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
    # 图形界面模式：把进度原文直接交出去，不补位、不回车。
    # 补位与 `r 是"控制台就地刷新"的手段，在文本框里只会变成
    # 一长串空格与重叠的乱码。界面自己会在状态区显示进度。
    if ($env:CCR_GUI -eq '1') {
        Write-Output $Text
        return
    }

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

    Write-ConsoleLine -Text ("`r" + $line) -Level $Color -NoNewline
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
        Write-ConsoleLine -Text ''
        $script:ProgressLineActive = $false
    }
}

# 子模块必须显式导出：本文件作为清单的 NestedModule 加载，
# 只有这里 Export-ModuleMember 列出的函数才会被清单汇总出去。
# 新增函数时这里与 lib\ChaoxingCourseRunner.psd1 的 FunctionsToExport 都要加。
Export-ModuleMember -Function Write-RunnerLog, Write-ProgressLine, Clear-ProgressLine, Write-ConsoleLine
