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
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
[DllImport("user32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT rect);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT rect, int size);
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
        # 保留参数以兼容旧调用，但当前实现不使用它：
        # 置前只在"页面确实不可见"时发生（窗口被完全遮住或最小化），
        # 那种情况本来就必须置前，否则 Chromium 会停掉视频。
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


function Get-ScreenWorkArea {
    <#
    .SYNOPSIS
        取主屏工作区（已排除任务栏）。
    .OUTPUTS
        PSCustomObject：@{ Left; Top; Width; Height }
    #>
    [CmdletBinding()]
    param()
    $wa = New-Object CcrVis.Win+RECT
    if ([CcrVis.Win]::SystemParametersInfo(0x0030, 0, [ref]$wa, 0)) {
        return [pscustomobject]@{
            Left   = $wa.Left
            Top    = $wa.Top
            Width  = $wa.Right - $wa.Left
            Height = $wa.Bottom - $wa.Top
        }
    }
    return $null
}

function Get-TerminalWindowHandle {
    <#
    .SYNOPSIS
        找当前终端窗口的顶层句柄。
    .DESCRIPTION
        终端可能由 Windows Terminal、conhost 或 OpenConsole 托管，
        可见窗口未必属于当前进程，因此：
          1. 先取 GetConsoleWindow()，再沿 owner 链走到顶层
          2. 若拿到的不是有效顶层窗口，则按进程名枚举顶层窗口
    .OUTPUTS
        IntPtr；找不到时返回 [IntPtr]::Zero
    #>
    [CmdletBinding()]
    param()

    # 路径 1：控制台窗口 + owner 链
    try {
        $h = [CcrVis.Win]::GetConsoleWindow()
        if ($h -ne [IntPtr]::Zero) {
            $top = $h
            for ($i = 0; $i -lt 8; $i++) {
                $owner = [CcrVis.Win]::GetWindow($top, 4)   # GW_OWNER
                if ($owner -eq [IntPtr]::Zero) { break }
                $top = $owner
            }
            if ($top -ne [IntPtr]::Zero -and [CcrVis.Win]::IsWindow($top)) { return $top }
            if ([CcrVis.Win]::IsWindow($h)) { return $h }
        }
    } catch {
        Write-CdpDiag ('GetConsoleWindow 失败: ' + $_.Exception.Message)
    }

    # 路径 2：按终端进程名枚举
    try {
        $myPid = [uint32]$global:PID
        $names = @('WindowsTerminal', 'conhost', 'OpenConsole', 'wt')
        foreach ($proc in @(Get-Process -Name $names -ErrorAction SilentlyContinue)) {
            if ($proc.MainWindowHandle -ne [IntPtr]::Zero) { return $proc.MainWindowHandle }
        }
        # 路径 3：退而求其次，当前进程自己的主窗口
        $self = Get-Process -Id $myPid -ErrorAction SilentlyContinue
        if ($self -and $self.MainWindowHandle -ne [IntPtr]::Zero) { return $self.MainWindowHandle }
    } catch {
        Write-CdpDiag ('枚举终端窗口失败: ' + $_.Exception.Message)
    }

    return [IntPtr]::Zero
}

function Get-WindowFrameInsets {
    <#
    .SYNOPSIS
        取窗口"不可见边框"的宽度（左/上/右/下）。
    .DESCRIPTION
        Windows 给可调整大小的窗口留了一圈不可见边框（鼠标移到边缘才出现
        缩放光标），GetWindowRect 返回的是含这圈边框的矩形。
        直接按矩形并排，可见部分会重叠或留缝。

        取值顺序：
          1. DwmGetWindowAttribute(DWMWA_EXTENDED_FRAME_BOUNDS) —— 系统实测
          2. 取不到或数值不合理 → Windows 标准边框 7px
             （无边框窗口、DWM 关闭、全屏窗口会走到这里）

        全程用系统 API，不含任何与具体机器绑定的假设。
    .OUTPUTS
        PSCustomObject：@{ Left; Top; Right; Bottom; Source }
        Source 为 'dwm' 或 'standard'，便于排查。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$Handle)

    # Windows 标准不可见边框（物理像素）。实测在 100%/125%/150% 缩放下相同。
    $std = 7
    $fallback = [pscustomobject]@{ Left = $std; Top = 0; Right = $std; Bottom = $std; Source = 'standard' }

    if ($Handle -eq [IntPtr]::Zero) { return $fallback }

    try {
        $wr = New-Object CcrVis.Win+RECT
        if (-not [CcrVis.Win]::GetWindowRect($Handle, [ref]$wr)) { return $fallback }

        $fr = New-Object CcrVis.Win+RECT
        if ([CcrVis.Win]::DwmGetWindowAttribute($Handle, 9, [ref]$fr, 16) -ne 0) { return $fallback }

        $l = $fr.Left - $wr.Left
        $tp = $fr.Top - $wr.Top
        $r = $wr.Right - $fr.Right
        $b = $wr.Bottom - $fr.Bottom

        # 合理性检查：差值应在 0..40；且可见区域不能大于窗口矩形
        foreach ($v in @($l, $tp, $r, $b)) {
            if ($v -lt 0 -or $v -gt 40) { return $fallback }
        }
        $visW = $fr.Right - $fr.Left
        $winW = $wr.Right - $wr.Left
        if ($visW -gt $winW -or ($fr.Bottom - $fr.Top) -gt ($wr.Bottom - $wr.Top)) { return $fallback }

        return [pscustomobject]@{ Left = $l; Top = $tp; Right = $r; Bottom = $b; Source = 'dwm' }
    } catch {
        return $fallback
    }
}

function Set-WindowHalf {
    <#
    .SYNOPSIS
        把窗口摆到屏幕的左半或右半，可见边界严格贴合，且不抢焦点。
    .DESCRIPTION
        步骤：
          1. 取工作区（SPI_GETWORKAREA，已排除任务栏）
          2. 取该窗口的不可见边框宽度（DWM 实测，取不到用标准值）
          3. 按"可见边界"计算窗口矩形并摆放
          4. 回读实际矩形，与目标比对；有偏差则按误差再修一次
        第 4 步是为了兜住个别窗口对尺寸请求的调整（最小宽度限制等），
        让结果在任何机器上都自洽，而不是假设一次调用就成功。
    .OUTPUTS
        PSCustomObject：@{ Ok; Side; X; Width; InsetSource; Corrected }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IntPtr]$Handle,
        [Parameter(Mandatory)][ValidateSet('left', 'right')][string]$Side
    )

    $result = [pscustomobject]@{
        Ok = $false; Side = $Side; X = 0; Width = 0
        InsetSource = ''; Corrected = $false
    }
    if ($Handle -eq [IntPtr]::Zero) { return $result }

    $wa = Get-ScreenWorkArea
    if (-not $wa) { return $result }

    $ins = Get-WindowFrameInsets -Handle $Handle
    $result.InsetSource = $ins.Source

    $halfW = [int]($wa.Width / 2)
    $visX = if ($Side -eq 'left') { $wa.Left } else { $wa.Left + $halfW }

    # 目标：可见左边界 = visX，可见宽度 = halfW
    $targetWinX = $visX - $ins.Left
    $targetWinW = $halfW + $ins.Left + $ins.Right
    $targetWinY = $wa.Top - $ins.Top
    $targetWinH = $wa.Height + $ins.Top + $ins.Bottom

    # SWP_NOACTIVATE(0x0010) | SWP_NOZORDER(0x0004)
    [void][CcrVis.Win]::SetWindowPos($Handle, [IntPtr]::Zero, $targetWinX, $targetWinY, $targetWinW, $targetWinH, 0x0014)

    # 回读并校正一次
    $wr = New-Object CcrVis.Win+RECT
    if ([CcrVis.Win]::GetWindowRect($Handle, [ref]$wr)) {
        $actualW = $wr.Right - $wr.Left
        $dx = $targetWinX - $wr.Left
        $dw = $targetWinW - $actualW
        if ($dx -ne 0 -or $dw -ne 0) {
            [void][CcrVis.Win]::SetWindowPos($Handle, [IntPtr]::Zero,
                $targetWinX, $targetWinY, $targetWinW, $targetWinH, 0x0014)
            $result.Corrected = $true
        }
        $result.X = $wr.Left
        $result.Width = $actualW
    }

    $result.Ok = $true
    return $result
}

function Arrange-Windows {
    <#
    .SYNOPSIS
        启动时一次性摆好窗口：浏览器一侧、终端另一侧。
    .DESCRIPTION
        两者并排后，进度条与终端输出都看得见，且不需要抢前台 ——
        Chromium 只要求窗口可见，不要求它在最前。
    .PARAMETER BrowserHandle
        浏览器主窗口句柄；[IntPtr]::Zero 时跳过浏览器。
    .PARAMETER BrowserSide
        浏览器放哪一侧，默认 'left'。
    .OUTPUTS
        PSCustomObject：@{ Browser; Terminal; BrowserHandle; TerminalHandle }
    #>
    [CmdletBinding()]
    param(
        [IntPtr]$BrowserHandle = [IntPtr]::Zero,
        [ValidateSet('left', 'right')][string]$BrowserSide = 'left'
    )

    $termSide = if ($BrowserSide -eq 'left') { 'right' } else { 'left' }
    $result = [pscustomobject]@{
        Browser        = $false
        Terminal       = $false
        BrowserHandle  = $BrowserHandle
        TerminalHandle = [IntPtr]::Zero
    }

    if ($BrowserHandle -ne [IntPtr]::Zero) {
        $result.Browser = (Set-WindowHalf -Handle $BrowserHandle -Side $BrowserSide).Ok
    }

    $term = Get-TerminalWindowHandle
    $result.TerminalHandle = $term
    if ($term -ne [IntPtr]::Zero) {
        $result.Terminal = (Set-WindowHalf -Handle $term -Side $termSide).Ok
    }

    return $result
}

Export-ModuleMember -Function Get-PageVisibility, Enable-LessonVideoPlayback, Get-ScreenWorkArea, Get-TerminalWindowHandle, Get-WindowFrameInsets, Set-WindowHalf, Arrange-Windows
