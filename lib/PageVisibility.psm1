<#
    页面可见性保障。

    ============================ 为什么必须做这件事 ============================
    Chromium 有一条硬性行为：**页面处于 hidden 状态时不允许加载/播放视频**。
    页面被判定为 hidden 时表现为：
      · document.visibilityState = 'hidden'
      · <video>.duration 一直是 null、readyState 0、networkState 2(LOADING)
      · networkState 会从 1 变 2，看起来在加载，但永远不完成

    而 hidden 的成因不只是"窗口最小化"：
      · 窗口在后台
      · 窗口在前台，但**目标不是活动标签页**（同窗口里切到了别的标签）
    第二种情况最隐蔽 —— 窗口是可见的，SetForegroundWindow 也成功，
    但页面依然 hidden。

    因此"让页面可见"需要两步：
      1. 窗口级：ShowWindow 恢复 + SetForegroundWindow
      2. 标签页级：CDP 的 Page.bringToFront

    这两步缺一不可。之前只做了第 1 步，导致视频永远不加载。
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CdpClient.psm1') -Force -DisableNameChecking

Add-Type -Namespace CcrVis -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@ -ErrorAction SilentlyContinue

function Get-PageVisibility {
    <#
    .SYNOPSIS
        读页面可见性。
    .PARAMETER ContextId
        目标上下文；0 表示顶层文档。
    .OUTPUTS
        String：'visible' / 'hidden' / 'prerender' / ''（读取失败）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [int]$ContextId = 0
    )
    $r = Invoke-CdpJs -Session $Session -Expression 'document.visibilityState' -ContextId $ContextId
    if ($r.Error) { return '' }
    return [string]$r.Value
}

function Enable-LessonVideoPlayback {
    <#
    .SYNOPSIS
        确保课程页与播放器帧都处于 visible，否则视频永远不会加载。
    .PARAMETER Session
        CDP 会话。
    .PARAMETER WindowHandle
        浏览器主窗口句柄；为 [IntPtr]::Zero 时跳过窗口级操作。
    .PARAMETER VideoContextId
        播放器帧上下文；为 0 时只处理顶层。
    .OUTPUTS
        PSCustomObject：@{ TopVisible; FrameVisible; WindowRestored; Ok }
    .NOTES
        调用时机：每次开始播放某节课之前。切换标签页或窗口失焦后都要重新调用。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [IntPtr]$WindowHandle = [IntPtr]::Zero,
        [int]$VideoContextId = 0
    )

    $result = [pscustomobject]@{
        TopVisible      = ''
        FrameVisible    = ''
        WindowRestored  = $false
        Ok              = $false
    }

    # ---- 0. 先只读可见性 ----
    # 已经可见就立刻返回：不抢前台、不激活标签、不 sleep。
    # 这一步很重要 —— 本函数会被播放循环每轮调用，
    # 若无条件执行下面的窗口操作，会每秒把浏览器抢到前台（终端没法用），
    # 而且每次带 1.5 秒固定等待，把轮询间隔从 1 秒拖成 2.5 秒。
    if ([int]$VideoContextId -gt 0) {
        $topNow = Get-PageVisibility -Session $Session -ContextId 0
        $frameNow = Get-PageVisibility -Session $Session -ContextId $VideoContextId
        if ($topNow -eq 'visible' -and $frameNow -eq 'visible') {
            $result.TopVisible = $topNow
            $result.FrameVisible = $frameNow
            $result.Ok = $true
            return $result
        }
    }

    # ---- 1. 窗口级：恢复 + 前台 ----
    if ($WindowHandle -ne [IntPtr]::Zero) {
        try {
            $iconic = [CcrVis.Win]::IsIconic($WindowHandle)
            if ($iconic) {
                [void][CcrVis.Win]::ShowWindow($WindowHandle, 9)   # SW_RESTORE
                $result.WindowRestored = $true
                Start-Sleep -Milliseconds 600
            } elseif (-not [CcrVis.Win]::IsWindowVisible($WindowHandle)) {
                [void][CcrVis.Win]::ShowWindow($WindowHandle, 5)   # SW_SHOW
                $result.WindowRestored = $true
                Start-Sleep -Milliseconds 600
            }
            [void][CcrVis.Win]::SetForegroundWindow($WindowHandle)
            # 只在确实需要恢复时等待，轮询路径不会走到这里
            Start-Sleep -Milliseconds 300
        } catch {
            Write-CdpDiag ("窗口恢复失败: " + $_.Exception.Message)
        }
    }

    # ---- 2. 标签页级：让目标标签成为活动标签 ----
    # 这一步是关键。窗口在前台但标签不活动时，页面仍是 hidden。
    try {
        Send-Cdp -Session $Session -Method 'Page.bringToFront' -Params @{} | Out-Null
    } catch {
        Write-CdpDiag ("Page.bringToFront 失败: " + $_.Exception.Message)
    }

    # ---- 3. 复核 ----
    $result.TopVisible = Get-PageVisibility -Session $Session -ContextId 0
    if ($VideoContextId -gt 0) {
        $result.FrameVisible = Get-PageVisibility -Session $Session -ContextId $VideoContextId
    }
    $result.Ok = ($result.TopVisible -eq 'visible')

    if (-not $result.Ok) {
        Write-CdpDiag ("页面仍不可见（顶层=" + $result.TopVisible + " 帧=" + $result.FrameVisible + "）")
    }
    return $result
}

Export-ModuleMember -Function Get-PageVisibility, Enable-LessonVideoPlayback
