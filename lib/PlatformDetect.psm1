<#
    平台版本识别。

    学习通存在两个并行的课程页版本，DOM 完全不同：

      legacy  mooc1-2.chaoxing.com
              目录在顶层文档，课节为 h5[id^=cur]，状态圆点 span.roundpoint

      mooc2   mooc1.chaoxing.com（URL 带 mooc2=1）
              目录在 iframe 内，课节为 div.posCatalog_select

    本模块负责：
      1. 判断当前页面是哪个版本
      2. 找出"目录所在的那个执行上下文"（可能是顶层，也可能是 iframe）
      3. 把 common + 对应版本的选择器合并成一张扁平表，交给其它模块使用

    为什么需要"扁平表"：
      Chaoxing.psm1 / Video.psm1 只想要一张直接取用的键值表，
      不应该关心版本分组的细节。版本差异在本模块内被消化掉。
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CdpClient.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Selectors.psm1') -Force -DisableNameChecking

function Merge-SelectorTable {
    <#
    .SYNOPSIS
        把 common 与某个版本的选择器合并成一张扁平表（内部辅助）。
    .NOTES
        版本块优先：同名键以版本块为准。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Raw,
        [Parameter(Mandatory)][string]$VersionName
    )

    if (-not $Raw.ContainsKey($VersionName)) { throw "选择器表里没有版本: $VersionName" }
    if (-not $Raw.ContainsKey('common')) { throw '选择器表缺少 common 区块' }

    $flat = @{}
    foreach ($k in $Raw.common.Keys) { $flat[$k] = $Raw.common[$k] }
    foreach ($k in $Raw[$VersionName].Keys) { $flat[$k] = $Raw[$VersionName][$k] }
    $flat['Version'] = $VersionName
    return $flat
}

function Test-DirectoryInContext {
    <#
    .SYNOPSIS
        在给定执行上下文里探测：是否含课节目录，以及是哪个版本（内部辅助）。
    .PARAMETER ContextId
        执行上下文 id；0 表示顶层主世界。
    .OUTPUTS
        Hashtable：@{ Legacy = <int>; Mooc2 = <int> }（各自命中元素数量）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [int]$ContextId = 0
    )

    $expr = 'JSON.stringify({Legacy:document.querySelectorAll("h5[id^=cur]").length,Mooc2:document.querySelectorAll("div.posCatalog_select").length,HasCur:!!document.getElementById("curChapterId")})'
    $r = Invoke-CdpJs -Session $Session -Expression $expr -ContextId $ContextId
    if ($r.Error -or -not $r.Value) { return @{ Legacy = 0; Mooc2 = 0; HasCur = $false } }
    try {
        $o = $r.Value | ConvertFrom-Json
        return @{ Legacy = [int]$o.Legacy; Mooc2 = [int]$o.Mooc2; HasCur = [bool]$o.HasCur }
    } catch {
        return @{ Legacy = 0; Mooc2 = 0; HasCur = $false }
    }
}

function Resolve-Platform {
    <#
    .SYNOPSIS
        识别平台版本，并定位"目录所在的执行上下文"。
    .PARAMETER Session
        CDP 会话（课程页所在标签页）。
    .PARAMETER RawSelectors
        Import-CourseSelectors 的原始返回（含 common 与各版本块）。
    .OUTPUTS
        PSCustomObject：
          Version       'legacy' / 'mooc2' / ''（识别失败）
          Selectors     合并后的扁平选择器表
          DirContextId  目录所在执行上下文 id（0 = 顶层）
          LegacyCount   legacy 课节节点数
          Mooc2Count    mooc2 目录条目数
    .NOTES
        探测顺序：先看顶层，再逐个 iframe。
        两个版本都可能把目录放在 iframe 里，所以不能只查顶层。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$RawSelectors
    )

    $result = [pscustomobject]@{
        Version      = ''
        Selectors    = $null
        DirContextId = 0
        LegacyCount  = 0
        Mooc2Count   = 0
    }

    # ---- 1. 顶层 ----
    $top = Test-DirectoryInContext -Session $Session -ContextId 0
    if ($top.Legacy -gt 0 -and $top.HasCur) {
        $result.Version = 'legacy'
        $result.LegacyCount = $top.Legacy
        $result.DirContextId = 0
        $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'legacy'
        return $result
    }
    if ($top.Mooc2 -gt 0) {
        $result.Version = 'mooc2'
        $result.Mooc2Count = $top.Mooc2
        $result.DirContextId = 0
        $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'mooc2'
        return $result
    }

    # ---- 2. 逐个 iframe ----
    foreach ($frame in (Get-CdpFrames -Session $Session)) {
        $ctx = 0
        try {
            $iso = Send-Cdp -Session $Session -Method 'Page.createIsolatedWorld' -Params @{
                frameId             = $frame.Id
                worldName           = 'ccrprobe' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
                grantUniveralAccess = $true
            }
            $ctx = [int](Get-CdpField -Object $iso -Path 'result.executionContextId')
        } catch { continue }
        if ($ctx -le 0) { continue }

        $probe = Test-DirectoryInContext -Session $Session -ContextId $ctx
        if ($probe.Mooc2 -gt 0) {
            $result.Version = 'mooc2'
            $result.Mooc2Count = $probe.Mooc2
            $result.DirContextId = $ctx
            $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'mooc2'
            Write-CdpDiag ("检测到 mooc2 版本，目录在帧内: " + $frame.Url)
            return $result
        }
        if ($probe.Legacy -gt 0 -and $probe.HasCur) {
            $result.Version = 'legacy'
            $result.LegacyCount = $probe.Legacy
            $result.DirContextId = $ctx
            $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'legacy'
            Write-CdpDiag ("检测到 legacy 版本，目录在帧内: " + $frame.Url)
            return $result
        }
    }

    # ---- 3. 识别失败：退回 legacy 选择器，让上层报"读不到目录" ----
    Write-CdpDiag '平台版本识别失败：顶层与所有帧都没找到课节目录'
    $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'legacy'
    return $result
}

function Get-CommonSelector {
    <#
    .SYNOPSIS
        从扁平表里取一个键；不存在则抛错（早失败优于到处判空）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Selectors,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Selectors.ContainsKey($Name)) { throw "选择器不存在: $Name" }
    return $Selectors[$Name]
}

Export-ModuleMember -Function Resolve-Platform, Merge-SelectorTable, Test-DirectoryInContext, Get-CommonSelector
