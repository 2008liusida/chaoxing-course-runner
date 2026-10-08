<#
    平台层之二：视频播放控制。

    依赖三层 iframe 结构（详见 lib\Selectors.psd1 的说明）：
        studentstudy -> knowledge/cards -> ananas/modules/video
    控制 <video> 必须进到最里层；读任务点完成状态在中间层。

    本模块只提供原子操作（读状态、播放、重播），
    "播到什么时候停""要不要重播"由 Run.ps1 决定。
#>

Set-StrictMode -Version Latest

# 跨模块依赖：ConvertTo-JsLiteral / Get-FrameContext 定义在 CdpClient.psm1。
# 显式引用，避免依赖"调用方恰好已经加载过 CdpClient"这种隐式约定。
Import-Module (Join-Path $PSScriptRoot 'CdpClient.psm1') -Force -DisableNameChecking

function Get-VideoContext {
    <#
    .SYNOPSIS
        获取播放器层 iframe 的执行上下文 id。
    .DESCRIPTION
        两条路：
          1) 按 URL 特征找（快）—— 绝大多数情况走这条；
          2) 找不到时，遍历所有帧找真正含 <video> 的那个（慢但通用）。
        第 2 条是兜底：各学校的播放器路径不一样，写死 URL 特征迟早会失效，
        失效时的表现是"这一节没有视频"，然后整节课被跳过 —— 静默漏刷，
        使用者很难发现。宁可多花一轮 CDP 也要找出来。
    .OUTPUTS
        Int32；该课节确实没有视频（例如作业/讨论类任务点）时返回 0。
    .EXAMPLE
        $vctx = Get-VideoContext -Session $s -Selectors $sel
        if ($vctx -le 0) { '这一节没有视频' }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors
    )

    $pattern = [string]$Selectors.VideoFramePattern
    $ctx = 0
    if ($pattern) {
        $ctx = [int](Get-FrameContext -Session $Session -UrlPattern $pattern)
    }
    if ($ctx -gt 0) { return $ctx }

    # URL 没匹配上 —— 不急着下"没有视频"的结论，先按 video 元素找一遍。
    Write-CdpDiag ('按 URL 特征 [' + $pattern + '] 没找到播放器帧，改用 video 元素查找')
    return [int](Find-VideoFrameContext -Session $Session)
}

function Get-AllVideoContexts {
    <#
    .SYNOPSIS
        列出本节所有视频任务点的执行上下文 id（按页面顺序）。
    .DESCRIPTION
        一节课可能有多个视频任务点。原来的 Get-VideoContext 只给第一个，
        导致多视频课节只播第一个就以为完事。
    .OUTPUTS
        Int32[]；本节没有视频时返回空数组。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors
    )
    $pattern = [string]$Selectors.VideoFramePattern
    if (-not $pattern) { return @() }
    return @(Get-VideoFrameContexts -Session $Session -UrlPattern $pattern)
}

function Get-CardsContext {
    <#
    .SYNOPSIS
        获取内容层 iframe 的执行上下文 id（任务点状态在这里）。
    .OUTPUTS
        Int32；找不到返回 0。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors
    )
    return Get-FrameContext -Session $Session -UrlPattern ([string]$Selectors.CardsFramePattern)
}

function Get-VideoState {
    <#
    .SYNOPSIS
        读取播放器状态。
    .PARAMETER ContextId
        播放器层的上下文 id（来自 Get-VideoContext）。
    .OUTPUTS
        PSCustomObject：
          Ok        是否成功读到 <video>
          Current   当前播放位置（秒）；读不到为 -1
          Duration  总时长（秒）；未加载为 0
          Paused    是否暂停
          ReadyState HTMLMediaElement.readyState
          Ended     是否已播完
          Rate      当前播放速率
          Error     失败原因（成功时为 $null）
    .NOTES
        Duration 为 0 不代表出错：学习通的视频常常要调用 play() 之后才开始加载。
        调用方应据此先触发播放，而不是当成失败。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$ContextId
    )

    $js = 'JSON.stringify((function(){var v=document.querySelector("video");if(!v)return{has:false};return{has:true,t:v.currentTime,d:v.duration,paused:v.paused,rs:v.readyState,ended:v.ended,rate:v.playbackRate};})())'
    $r = Invoke-CdpJs -Session $Session -Expression $js -ContextId $ContextId

    $fail = [pscustomobject]@{
        Ok = $false; Current = -1.0; Duration = 0.0
        Paused = $true; ReadyState = 0; Ended = $false; Rate = 1.0; Error = $null
    }
    if ($r.Error) { $fail.Error = $r.Error; return $fail }

    try {
        $o = $r.Value | ConvertFrom-Json
        if (-not $o.has) { $fail.Error = '该层没有 <video> 元素'; return $fail }

        $current = 0.0; $duration = 0.0
        if ($null -ne $o.t) { $current = [double]$o.t }
        if ($null -ne $o.d) { $duration = [double]$o.d }

        return [pscustomobject]@{
            Ok         = $true
            Current    = $current
            Duration   = $duration
            Paused     = [bool]$o.paused
            ReadyState = [int]$o.rs
            Ended      = [bool]$o.ended
            Rate       = [double]$o.rate
            Error      = $null
        }
    } catch {
        $fail.Error = $_.Exception.Message
        return $fail
    }
}

function Start-VideoPlayback {
    <#
    .SYNOPSIS
        开始/继续播放，并强制把速率拉回目标值。
    .PARAMETER Rate
        目标速率，默认 1.0。平台会检测倍速，非 1 倍可能不计入时长，
        所以这里会主动纠正被插件或页面改过的速率。
    .OUTPUTS
        String：'ok' / 'novideo' / 'err:<异常名>' / 错误描述。
    .NOTES
        求值时带 userGesture = $true，否则部分浏览器会以
        "play() failed because the user didn't interact with the document" 拒绝播放。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$ContextId,
        [double]$Rate = 1.0
    )

    # 关键：绝不返回 play() 的 Promise。
    # play() 的 Promise 在视频真正开始播放前不会兑现，而视频往往需要等待加载；
    # 若让求值去 await 它，这条 CDP 连接会被挂住，后续所有命令都会超时。
    # 所以这里只"发出"播放请求并立即返回，是否真在播由调用方轮询 Get-VideoState 判断。
    $js = @"
(function () {
  var v = document.querySelector('video');
  if (!v) { return 'novideo'; }
  try { if (Math.abs(v.playbackRate - $Rate) > 0.01) { v.playbackRate = $Rate; } } catch (e) { }
  try {
    var p = v.play();
    if (p && p.catch) { p.catch(function () { }); }
  } catch (e) { return 'throw:' + e.name; }
  return 'ok';
})()
"@
    $r = Invoke-CdpJs -Session $Session -Expression $js -ContextId $ContextId -NoAwait
    if ($r.Error) { return $r.Error }
    return [string]$r.Value
}

function Restart-Video {
    <#
    .SYNOPSIS
        从头重播当前视频。
    .NOTES
        用于"视频已播完但平台未登记完成"的情况（通常因为该节要求 100% 时长）。
        只让播放器自己回到起点，不做任何进度条拖拽。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$ContextId,
        [double]$Rate = 1.0
    )

    # 同样不等待 play() 的 Promise，理由见 Start-VideoPlayback。
    $js = @"
(function () {
  var v = document.querySelector('video');
  if (!v) { return 'novideo'; }
  try { v.currentTime = 0; } catch (e) { }
  try { v.playbackRate = $Rate; } catch (e) { }
  try {
    var p = v.play();
    if (p && p.catch) { p.catch(function () { }); }
  } catch (e) { return 'throw:' + e.name; }
  return 'ok';
})()
"@
    $r = Invoke-CdpJs -Session $Session -Expression $js -ContextId $ContextId -NoAwait
    if ($r.Error) { return $r.Error }
    return [string]$r.Value
}

function Get-JobIconClass {
    <#
    .SYNOPSIS
        读取内容层任务点图标的 class。
    .OUTPUTS
        String；找不到返回空字符串。
    .NOTES
        class 含 Selectors.JobIconClear（默认 'clear'）= 未完成。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [Parameter(Mandatory)][int]$ContextId
    )
    $sel = ConvertTo-JsLiteral -Value ([string]$Selectors.JobIcon)
    $r = Invoke-CdpJs -Session $Session -Expression "var e=document.querySelector('$sel'); e?e.className:''" -ContextId $ContextId
    if ($r.Error) { return '' }
    return [string]$r.Value
}

function Test-JobFinished {
    <#
    .SYNOPSIS
        判断当前课节的任务点是否已被平台标记完成。
    .OUTPUTS
        Boolean
    .NOTES
        依据是内容层存在 .ans-job-finished 元素。这是"平台真的认可了"的信号，
        比单纯看播放位置可靠。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [Parameter(Mandatory)][int]$ContextId
    )
    $sel = ConvertTo-JsLiteral -Value ([string]$Selectors.JobFinished)
    $r = Invoke-CdpJs -Session $Session -Expression "!!document.querySelector('$sel')" -ContextId $ContextId
    if ($r.Error) { return $false }
    return ([string]$r.Value -eq 'true')
}

