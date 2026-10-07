<#
    配置读取。

    解析规则见 Read-RunnerConfigFile 的注释。对外只需要用 Get-RunnerSettings：
    它把"默认值 -> 配置文件 -> 命令行覆盖"三层合并成一个对象。

    路径解析的约定：
      ProfileDir / LogFile 若为相对路径，一律相对于"工具根目录"（lib 的上一级），
      而不是相对于当前工作目录 —— 这样双击 Start.bat 和从别处调用结果一致。
#>

Set-StrictMode -Version Latest

function Read-RunnerConfigFile {
    <#
    .SYNOPSIS
        解析 config.psd1，返回键值哈希表。
    .DESCRIPTION
        自己解析而不使用 Import-PowerShellDataFile，原因：
        Windows PowerShell 5.1 的 Import-PowerShellDataFile 无法解析
        带 UTF-8 BOM 的 psd1，而带 BOM 又是 5.1 正确识别中文所必需的。

        支持的语法（够用即可，且不执行文件内任何代码）：
          键 = 值            值可为 '字符串' / "字符串" / 数字 / $true / $false
          # 注释             只在引号外生效
          行尾注释           同上

        不认识的键会被忽略；不支持的语法会被安静跳过（不报错），
        以免用户改配置时因为格式小问题就无法启动。
    .PARAMETER Path
        配置文件路径。
    .OUTPUTS
        Hashtable
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = @{}
    if (-not (Test-Path $Path)) { return $result }

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    # 去掉可能的 BOM，否则首行的键名会被拼上不可见字符，
    # 表现为"配置明明改了却没生效"这类很难查的问题。
    $text = $text.TrimStart([char]0xFEFF)
    foreach ($rawLine in ($text -split "`r?`n")) {
        $line = $rawLine.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }
        if ($line -eq '@{' -or $line -eq '}') { continue }

        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }

        $key = $line.Substring(0, $eq).Trim()
        # 配置沿用 PowerShell 数据文件的写法（$SwitchMode = 'auto'）。
        # 这里统一去掉前缀 $，否则键名对不上默认值表，
        # 表现为"改了配置却不生效"这种很难查的问题。
        $key = $key.TrimStart('$')
        $val = $line.Substring($eq + 1).Trim()

        # 去掉行尾注释（引号外的 # 才算）
        $inSingle = $false; $inDouble = $false; $cut = -1
        for ($i = 0; $i -lt $val.Length; $i++) {
            $ch = $val[$i]
            if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle }
            elseif ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble }
            elseif ($ch -eq '#' -and -not $inSingle -and -not $inDouble) { $cut = $i; break }
        }
        if ($cut -ge 0) { $val = $val.Substring(0, $cut).Trim() }

        # 去引号
        if ($val.Length -ge 2) {
            $f = $val[0]; $l = $val[$val.Length - 1]
            if (($f -eq "'" -and $l -eq "'") -or ($f -eq '"' -and $l -eq '"')) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        if ($key) { $result[$key] = $val }
    }
    return $result
}

function ConvertTo-RunnerValue {
    <#
    .SYNOPSIS
        按默认值的类型把配置里的字符串转成目标类型（内部辅助）。
    .NOTES
        转换失败返回 $null，由调用方决定是忽略该项还是用默认值。
    #>
    [CmdletBinding()]
    param($Raw, $Like)

    if ($Raw -isnot [string]) { return $Raw }
    $s = $Raw.Trim()
    if ($s -eq '') { return $null }

    switch ($Like.GetType().Name) {
        'Int32' { $n = 0; if ([int]::TryParse($s, [ref]$n)) { return $n } else { return $null } }
        'Int64' { $n = 0L; if ([long]::TryParse($s, [ref]$n)) { return $n } else { return $null } }
        'Double' { $n = 0.0; if ([double]::TryParse($s, [ref]$n)) { return $n } else { return $null } }
        'Boolean' {
            if ($s -match '^(?i)(true|1|yes|on)$') { return $true }
            if ($s -match '^(?i)(false|0|no|off)$') { return $false }
            return $null
        }
        default { return $s }
    }
}

function Get-RunnerSettings {
    <#
    .SYNOPSIS
        合并默认值、配置文件与命令行覆盖，返回最终设置对象。
    .PARAMETER ConfigPath
        config.psd1 路径。不存在时全部使用默认值。
    .PARAMETER Overrides
        命令行覆盖项。值为 $null 或空字符串的项会被跳过（表示"未指定"）。
    .OUTPUTS
        PSCustomObject，字段与 config.psd1 的键一致，外加 Root（工具根目录）。
    .EXAMPLE
        $cfg = Get-RunnerSettings -ConfigPath .\config.psd1 -Overrides @{ DebugPort = 9223 }
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [hashtable]$Overrides = @{}
    )

    # 默认值同时充当"类型模板"：配置文件里的字符串按这里的类型转换
    $defaults = [ordered]@{
        Browser                 = 'msedge'
        DebugPort               = 9222
        ProfileDir              = ''
        StartUrl                = 'https://passport2.chaoxing.com/login'
        SwitchMode              = 'auto'
        LessonIds               = ''
        MaxLessons              = 50
        MaxReplayPerLesson      = 1
        MaxWaitMinutesPerLesson = 40
        PlaybackRate            = 1.0
        PollSeconds             = 1
        KeepForeground          = $true
        ArrangeWindows          = $true
        LogFile                 = 'logs\run.log'
    }

    $fromFile = @{}
    if ($ConfigPath -and (Test-Path $ConfigPath)) {
        $raw = Read-RunnerConfigFile -Path $ConfigPath
        foreach ($k in $raw.Keys) {
            if (-not $defaults.Contains($k)) { continue }        # 未知键忽略，避免用户笔误导致启动失败
            $converted = ConvertTo-RunnerValue -Raw $raw[$k] -Like $defaults[$k]
            if ($null -ne $converted) { $fromFile[$k] = $converted }
        }
    }

    $merged = @{}
    foreach ($k in $defaults.Keys) { $merged[$k] = $defaults[$k] }
    foreach ($k in $fromFile.Keys) { $merged[$k] = $fromFile[$k] }
    foreach ($k in $Overrides.Keys) {
        if ($null -eq $Overrides[$k]) { continue }
        if ($Overrides[$k] -is [string] -and $Overrides[$k] -eq '') { continue }
        $merged[$k] = $Overrides[$k]
    }

    # 工具根目录 = lib 的上一级
    $root = Split-Path -Parent $PSScriptRoot

    if (-not $merged.ProfileDir) {
        $merged.ProfileDir = Join-Path $root 'browser-profile'
    } elseif (-not [System.IO.Path]::IsPathRooted($merged.ProfileDir)) {
        $merged.ProfileDir = Join-Path $root $merged.ProfileDir
    }

    if (-not [System.IO.Path]::IsPathRooted($merged.LogFile)) {
        $merged.LogFile = Join-Path $root $merged.LogFile
    }

    $merged.Root = $root

    # 基本校验：把明显写错的配置拦在启动阶段，并给出可操作的提示
    if ($merged.SwitchMode -notin @('auto', 'click')) {
        throw "配置项 SwitchMode 只能是 'auto' 或 'click'，当前值: $($merged.SwitchMode)"
    }
    if ($merged.PlaybackRate -le 0) {
        throw "配置项 PlaybackRate 必须大于 0，当前值: $($merged.PlaybackRate)"
    }
    if ($merged.PollSeconds -lt 1) {
        throw "配置项 PollSeconds 至少为 1，当前值: $($merged.PollSeconds)"
    }

    return [pscustomobject]$merged
}

