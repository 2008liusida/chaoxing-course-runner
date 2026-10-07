<#
    选择器契约的加载与访问。

    为什么要自己解析 lib\Selectors.psd1，而不用 Import-PowerShellDataFile？
    ------------------------------------------------------------------
    因为 Windows PowerShell 5.1 的 Import-PowerShellDataFile 无法解析
    带 UTF-8 BOM 的 psd1 文件，而带 BOM 又是 5.1 正确识别中文的前提。
    本项目要求同时兼容 5.1 与 7.x，所以这里用一个只支持
    "键 = 值" / 嵌套 @{} / @() 的极简解析器，且不执行文件内任何代码。
#>

Set-StrictMode -Version Latest

function Read-CourseSelectorTable {
    <#
    .SYNOPSIS
        解析 Selectors.psd1（极简 PSD1 子集：字符串、布尔、数字、嵌套哈希、字符串数组）。
    .NOTES
        私有辅助函数，不对外导出。解析失败会抛出，因为选择器表损坏时
        整个工具都无法工作，早失败比晚失败好。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path)) { throw "选择器文件不存在: $Path" }

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    # 去掉可能的 BOM：否则文件首行的键名会被拼上不可见字符，
    # 表现为"配置明明改了却没生效"这类很难查的问题。
    $text = $text.TrimStart([char]0xFEFF)
    $lines = $text -split "`r?`n"

    # 逐行扫描，维护 3 层栈：
    #   containers : hashtable 栈；栈顶是当前正在填充的哈希表
    #   keys       : 与 containers 对应的"待赋值键名"
    #   arrayKeys  : 数组元素栈；非空时值被压入该数组而不是赋给键
    $containers = New-Object System.Collections.Generic.List[hashtable]
    $keys = New-Object System.Collections.Generic.List[string]
    $arrayKeys = New-Object System.Collections.Generic.List[object]
    $root = $null
    $inBlockComment = $false

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineNo = $i + 1
        $line = $lines[$i].Trim()

        # 块注释 <# ... #> 整体跳过。
        # 必须真正跟踪状态：注释正文里常出现 "xxx = yyy" 这类说明，
        # 不跳过会被误当成赋值，报出"内容出现在最外层哈希之外"。
        if ($inBlockComment) {
            if ($line.Contains('#>')) { $inBlockComment = $false }
            continue
        }
        if ($line.StartsWith('<#')) {
            if (-not $line.Contains('#>')) { $inBlockComment = $true }
            continue
        }

        if (-not $line) { continue }
        if ($line.StartsWith('#')) { continue }

        # 嵌套哈希：写法是 "Key = @{" 一行（也兼容孤立的 "@{"）。
        # 必须在通用键值处理之前判断，否则 "@{" 会被当成普通值。
        if ($line.EndsWith('@{')) {
            $leftPart = $line.Substring(0, $line.Length - 2).Trim()
            $new = @{}
            if ($containers.Count -eq 0) {
                # 最外层："@{"
                if ($leftPart) { throw "Selectors.psd1 第 $lineNo 行: 最外层不应有键名" }
                $root = $new
            } else {
                $parent = $containers[$containers.Count - 1]
                $keyName = $keys[$keys.Count - 1]
                if ($leftPart) {
                    $eqOpen = $leftPart.IndexOf('=')
                    if ($eqOpen -lt 1) { throw "Selectors.psd1 第 $lineNo 行: 嵌套哈希行缺少键名" }
                    $keyName = $leftPart.Substring(0, $eqOpen).Trim()
                }
                if (-not $keyName) { throw "Selectors.psd1 第 $lineNo 行: 出现嵌套哈希但没有键名" }
                $parent[$keyName] = $new
            }
            $containers.Add($new)
            $keys.Add('')
            continue
        }
        if ($line -eq '}') {
            if ($containers.Count -le 0) { throw "Selectors.psd1 第 $lineNo 行: 多余的 '}'" }
            $containers.RemoveAt($containers.Count - 1)
            $keys.RemoveAt($keys.Count - 1)
            continue
        }
        # 数组：实际写法是 "Key = @(" 一行，而不是孤立的 "@("，
        # 所以要判断"行尾是 @("，并从左侧取出键名。
        if ($line.EndsWith('@(')) {
            if ($containers.Count -le 0) { throw "Selectors.psd1 第 $lineNo 行: 顶层数组不支持" }
            $parent = $containers[$containers.Count - 1]
            $leftPart = $line.Substring(0, $line.Length - 2).Trim()
            $keyName = $keys[$keys.Count - 1]
            if ($leftPart) {
                $eqOpen = $leftPart.IndexOf('=')
                if ($eqOpen -lt 1) { throw "Selectors.psd1 第 $lineNo 行: 数组行缺少键名" }
                $keyName = $leftPart.Substring(0, $eqOpen).Trim()
            }
            if (-not $keyName) { throw "Selectors.psd1 第 $lineNo 行: 出现数组但没有键名" }
            $arr = New-Object System.Collections.Generic.List[string]
            $parent[$keyName] = $arr
            $arrayKeys.Add($arr)
            continue
        }
        if ($line -eq ')') {
            if ($arrayKeys.Count -gt 0) { $arrayKeys.RemoveAt($arrayKeys.Count - 1) }
            continue
        }

        if ($containers.Count -le 0) { throw "Selectors.psd1 第 $lineNo 行: 内容出现在最外层哈希之外" }
        $current = $containers[$containers.Count - 1]

        # 在数组内部：整行是一个元素。
        # 关键点：元素内容本身可能含 '='（例如选择器 'h5[id^=cur]'），
        # 所以这里先判断"是不是 key = value"形态：只接受左侧为纯标识符的行。
        # 否则一律当成元素，避免元素被误解析成键值对。
        if ($arrayKeys.Count -gt 0) {
            $arr = $arrayKeys[$arrayKeys.Count - 1]
            $eqInArray = $line.IndexOf('=')
            $looksLikeKey = $false
            if ($eqInArray -gt 0) {
                $left = $line.Substring(0, $eqInArray).Trim()
                $looksLikeKey = ($left -match '^[A-Za-z_][A-Za-z0-9_]*$')
            }
            if ($looksLikeKey) {
                $keys[$keys.Count - 1] = $line.Substring(0, $eqInArray).Trim()
                $arrayKeys.RemoveAt($arrayKeys.Count - 1)
                # 不 continue：交给下面的通用逻辑处理这个键
            } else {
                $arr.Add((ConvertTo-SelectorScalar $line)) | Out-Null
                continue
            }
        }

        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim().TrimStart('$')
        $value = $line.Substring($eq + 1).Trim()

        if ($value -eq '@{') {
            $keys[$keys.Count - 1] = $key
            continue
        }
        if ($value -eq '@(') {
            $keys[$keys.Count - 1] = $key
            continue
        }

        $current[$key] = ConvertTo-SelectorScalar $value
    }

    if ($containers.Count -ne 0) { throw "Selectors.psd1 结构不完整：有未闭合的 @{ 或 @(" }
    if ($root -eq $null) { throw "Selectors.psd1 解析结果为空" }
    return $root
}

function ConvertTo-SelectorScalar {
    <#
    .SYNOPSIS
        把 PSD1 里的一个字面量转成对应的标量值（内部辅助）。
    #>
    [CmdletBinding()]
    param([string]$Raw)

    $v = $Raw.Trim()
    # 去掉行尾注释（引号外的 # 才算注释）
    $inSingle = $false; $inDouble = $false; $cut = -1
    for ($i = 0; $i -lt $v.Length; $i++) {
        $ch = $v[$i]
        if ($ch -eq "'" -and -not $inDouble) { $inSingle = -not $inSingle }
        elseif ($ch -eq '"' -and -not $inSingle) { $inDouble = -not $inDouble }
        elseif ($ch -eq '#' -and -not $inSingle -and -not $inDouble) { $cut = $i; break }
    }
    if ($cut -ge 0) { $v = $v.Substring(0, $cut).Trim() }

    if ($v.Length -ge 2) {
        $first = $v[0]; $last = $v[$v.Length - 1]
        if (($first -eq "'" -and $last -eq "'") -or ($first -eq '"' -and $last -eq '"')) {
            return $v.Substring(1, $v.Length - 2)
        }
    }
    if ($v -match '^(?i)(true|false)$') { return ($v -match '(?i)^true$') }
    if ($v -match '^-?\d+$') { return [int]$v }
    if ($v -match '^-?\d+\.\d+$') { return [double]$v }
    return $v
}

function Import-CourseSelectors {
    <#
    .SYNOPSIS
        载入选择器契约表（原始结构，未按平台版本合并）。
    .DESCRIPTION
        返回结构：
          @{ legacy = @{...}; mooc2 = @{...}; common = @{...} }
        具体用哪一版由 lib\PlatformDetect.psm1 的 Resolve-Platform 识别后合并。
        本函数只负责"读文件 + 校验完整性"。
    .PARAMETER Path
        选择器文件路径。默认取本模块同目录下的 Selectors.psd1。
    .OUTPUTS
        Hashtable
    #>
    [CmdletBinding()]
    param([string]$Path)

    if (-not $Path) { $Path = Join-Path $PSScriptRoot 'Selectors.psd1' }
    $table = Read-CourseSelectorTable -Path $Path

    # 结构校验：早失败优于后面到处判空
    foreach ($section in @('common', 'legacy', 'mooc2')) {
        if (-not $table.ContainsKey($section)) {
            throw "选择器文件缺少 '$section' 区块（文件: $Path）"
        }
    }

    $missing = @()

    $commonRequired = @(
        'CourseId', 'ClazzId', 'SwitchFunction',
        'CardsFramePattern', 'VideoFramePattern',
        'JobIcon', 'JobIconClear', 'JobFinished',
        'LoginPasswordInput', 'LoginUrlPattern', 'PageFingerprints'
    )
    foreach ($k in $commonRequired) {
        if (-not $table.common.ContainsKey($k)) { $missing += ('common.' + $k) }
    }

    $versionRequired = @('LessonNode', 'LessonIdPrefix', 'DirectoryInFrame', 'UnfinishedBy')
    foreach ($ver in @('legacy', 'mooc2')) {
        foreach ($k in $versionRequired) {
            if (-not $table[$ver].ContainsKey($k)) { $missing += ($ver + '.' + $k) }
        }
    }

    if ($missing.Count -gt 0) {
        throw ("选择器文件缺少必需项: " + ($missing -join ', ') + "（文件: $Path）")
    }
    return $table
}

function Get-CourseSelector {
    <#
    .SYNOPSIS
        取单个选择器值。
    .EXAMPLE
        Get-CourseSelector -Table $sel -Name 'LessonNode'
        # => h5[id^=cur]
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Table,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Table.ContainsKey($Name)) { throw "选择器不存在: $Name" }
    return $Table[$Name]
}

