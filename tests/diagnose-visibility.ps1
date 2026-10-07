<#
    验证"窗口可见性导致无法播放"这个结论：
      1. 读窗口是否最小化
      2. 恢复窗口 + 激活课程页标签页
      3. 重新读 visibilityState 与视频状态
      4. 再调 play()，看进度是否开始走
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

Add-Type -Namespace W -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking
Set-CdpLogPath -Path (Join-Path $root 'logs\vis.log')
$raw = Import-CourseSelectors

# ---- 找课程页标签页与浏览器主窗口 ----
$page = $null
foreach ($t in (Get-CdpTargets -Port 9222)) { if ($t.type -eq 'page' -and $t.url -match 'studentstudy') { $page = $t; break } }
if (-not $page) { Write-Output '找不到课程页'; exit 1 }

$hwnd = Get-BrowserWindowHandle
Write-Output ('浏览器主窗口 hwnd = ' + $hwnd.ToInt64())
Write-Output ('  可见       = ' + [W.Win]::IsWindowVisible($hwnd))
Write-Output ('  最小化     = ' + [W.Win]::IsIconic($hwnd))

# ---- 恢复窗口 + 前台 ----
Write-Output ''
Write-Output '=== 恢复窗口并置于前台 ==='
if ([W.Win]::IsIconic($hwnd)) {
    [void][W.Win]::ShowWindow($hwnd, 9)      # SW_RESTORE
    Write-Output '  已从最小化恢复'
} else {
    [void][W.Win]::ShowWindow($hwnd, 5)      # SW_SHOW
    Write-Output '  未最小化，已确保显示'
}
[void][W.Win]::SetForegroundWindow($hwnd)
Start-Sleep -Seconds 3
Write-Output ('  恢复后最小化 = ' + [W.Win]::IsIconic($hwnd))

# ---- 激活课程页标签页（通过 CDP 让该 target 前置）----
Write-Output ''
Write-Output '=== 激活课程页标签页 ==='
$s = New-CdpSession -Page $page -Port 9222
try {
    # Page.bringToFront 让该标签页成为活动标签
    $bf = Send-Cdp -Session $s -Method 'Page.bringToFront' -Params @{}
    Write-Output ('  bringToFront 已调用')

    $plat = Resolve-Platform -Session $s -RawSelectors $raw
    $sel = $plat.Selectors
    Start-Sleep -Seconds 2

    Write-Output ''
    Write-Output '=== 可见性检查 ==='
    Write-Output ('  顶层 visibilityState = ' + (Invoke-CdpJs -Session $s -Expression 'document.visibilityState').Value)

    $vctx = Get-VideoContext -Session $s -Selectors $sel
    Write-Output ('  播放器上下文 = ' + $vctx)
    if ($vctx -gt 0) {
        Write-Output ('  帧 visibilityState  = ' + (Invoke-CdpJs -Session $s -Expression 'document.visibilityState' -ContextId $vctx).Value)

        $st = Get-VideoState -Session $s -ContextId $vctx
        Write-Output ('  视频: 位置=' + [math]::Round($st.Current, 1) + ' 时长=' + [math]::Round($st.Duration, 1) + ' 暂停=' + $st.Paused)

        Write-Output ''
        Write-Output '=== 调 play() 并观察 25 秒 ==='
        $r = Start-VideoPlayback -Session $s -ContextId $vctx -Rate 1.0
        Write-Output ('  play(): ' + $r)
        Start-Sleep -Seconds 10
        $a = Get-VideoState -Session $s -ContextId $vctx
        Write-Output ('  +10s: 位置=' + [math]::Round($a.Current, 1) + ' 时长=' + [math]::Round($a.Duration, 1) + ' 暂停=' + $a.Paused)
        Start-Sleep -Seconds 15
        $b = Get-VideoState -Session $s -ContextId $vctx
        Write-Output ('  +25s: 位置=' + [math]::Round($b.Current, 1) + ' 时长=' + [math]::Round($b.Duration, 1) + ' 暂停=' + $b.Paused)
        $delta = $b.Current - $a.Current
        Write-Output ('  结论: ' + $(if ($b.Duration -gt 0 -and $delta -gt 5) { '视频正常加载并播放' } elseif ($b.Duration -gt 0) { '已加载但进度异常' } else { '仍未加载' }))

        # 暂停，避免影响后续
        [void](Invoke-CdpJs -Session $s -Expression 'var v=document.querySelector("video"); if(v){v.pause();} "ok"' -ContextId $vctx)
    }
} finally {
    Close-CdpSession -Session $s
}
