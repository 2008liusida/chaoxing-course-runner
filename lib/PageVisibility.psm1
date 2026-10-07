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
      1. 窗口级：窗口必须显示在屏幕上（ShowWindow 恢复）
      2. 标签页级：目标标签必须是该窗口的活动标签（CDP 的 Page.bringToFront）

    注意**不需要** SetForegroundWindow：窗口可见即可，
    哪怕它被别的窗口盖住、或在后台。抢焦点只会妨碍使用者操作终端，
    所以默认不做；确需置前时用 -Activate。
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CdpClient.psm1') -Force -DisableNameChecking

Add-Type -Namespace CcrVis -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, ref RECT rect, uint winIni);
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
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
        [int]$VideoContextId = 0,
        # 需要时把浏览器强制置前。默认不置前，以免妨碍操作终端。
        [switch]$Activate,
        # 把浏览器摆到屏幕左侧一半，便于与终端并排查看。
        [switch]$SideBySide
    )

    $result = [pscustomobject]@{
        TopVisible      = ''
        FrameVisible    = ''
        WindowRestored  = $false
        Ok              = $false
    }

    # ---- 0a. 并排摆放（独立步骤）----
    # 必须在可见性快速返回之前做，否则页面已经 visible 时永远摆不到位。
    # 用 SWP_NOACTIVATE，只改位置与大小，不抢焦点。
    if ($SideBySide -and $WindowHandle -ne [IntPtr]::Zero) {
        try {
            $wa = New-Object CcrVis.Win+RECT
            $okSpi = [CcrVis.Win]::SystemParametersInfo(0x0030, 0, [ref]$wa, 0)   # SPI_GETWORKAREA
            if ($okSpi) {
                $scrW = $wa.Right - $wa.Left
                $scrH = $wa.Bottom - $wa.Top
                [void][CcrVis.Win]::SetWindowPos($WindowHandle, [IntPtr]::Zero,
                    $wa.Left, $wa.Top, [int]($scrW / 2), $scrH, 0x0010 -bor 0x0004)
            } else {
                Write-CdpDiag '取屏幕工作区失败，跳过并排摆放'
            }
        } catch {
            Write-CdpDiag ('并排摆放失败: ' + $_.Exception.Message)
        }
    }

    # ---- 0b. 先只读可见性 ----
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

    # ---- 1. 窗口级：确保窗口显示在屏幕上（不抢前台）----
    # 关键：Chromium 只要求窗口"可见"，不要求它在最前。
    # 抢焦点会让人没法用终端，所以默认不做。
    if ($WindowHandle -ne [IntPtr]::Zero) {
        try {
            $iconic = [CcrVis.Win]::IsIconic($WindowHandle)
            if ($iconic) {
                [void][CcrVis.Win]::ShowWindow($WindowHandle, 9)   # SW_RESTORE
                $result.WindowRestored = $true
                Start-Sleep -Milliseconds 600
            } elseif (-not [CcrVis.Win]::IsWindowVisible($WindowHandle)) {
                # SW_SHOWNOACTIVATE：显示但不激活，避免抢走焦点
                [void][CcrVis.Win]::ShowWindow($WindowHandle, 4)
                $result.WindowRestored = $true
                Start-Sleep -Milliseconds 600
            }

            # 走到这里说明第 0b 步判定页面不可见（窗口被完全遮住、最小化等）。
            # 此时置前是必要的 —— 窗口不可见时 Chromium 会停掉视频。
            # 正常并排可见的情况下不会执行到这里，所以不会干扰操作终端。
            # 走到这里说明页面确实不可见，置前是必要的
            [void][CcrVis.Win]::SetForegroundWindow($WindowHandle)
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
