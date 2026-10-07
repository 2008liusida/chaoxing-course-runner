<#
    浏览器进程层：找到可执行文件、启动带调试端口的实例、关闭本工具启动的实例。

    一条重要原则：**只操作本工具专用配置目录的浏览器实例**。
    Stop-DebugBrowser 通过命令行参数匹配 profile 目录来定位进程，
    不会误杀使用者日常在用的浏览器。
#>

Set-StrictMode -Version Latest

function Find-BrowserExe {
    <#
    .SYNOPSIS
        定位浏览器可执行文件。
    .DESCRIPTION
        查找顺序：注册表 App Paths（按 $Preferred 优先）-> 常见安装路径。
        兼容 Edge / Chrome / Brave；找到第一个存在的即返回。
    .PARAMETER Preferred
        优先尝试的名字（不带 .exe），如 'msedge'、'chrome'。
    .OUTPUTS
        String 路径；一个都没找到返回 $null。
    .EXAMPLE
        $exe = Find-BrowserExe -Preferred 'msedge'
    #>
    [CmdletBinding()]
    param([string]$Preferred = '')

    $candidates = New-Object System.Collections.Generic.List[string]

    $names = @()
    if ($Preferred) { $names += $Preferred }
    $names += @('msedge', 'chrome', 'brave', 'chromium')

    foreach ($n in $names) {
        foreach ($hive in @('HKLM:', 'HKCU:')) {
            $key = "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$n.exe"
            try {
                $v = (Get-ItemProperty -Path $key -ErrorAction Stop).'(default)'
                if ($v -and (Test-Path $v)) { $candidates.Add($v) }
            } catch { }
        }
    }

    $commonPaths = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles\BraveSoftware\Brave-Browser\Application\brave.exe"
    )
    foreach ($p in $commonPaths) { if ($p -and (Test-Path $p)) { $candidates.Add($p) } }

    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0]
}

function Start-DebugBrowser {
    <#
    .SYNOPSIS
        用独立配置目录启动浏览器，并等待调试端口就绪。
    .PARAMETER Exe
        浏览器可执行文件路径。
    .PARAMETER Port
        调试端口。
    .PARAMETER ProfileDir
        用户配置目录（保存登录态）。会在不存在时自动创建。
    .PARAMETER StartUrl
        启动时打开的页面。默认学习通登录页，便于首次登录。
    .OUTPUTS
        Boolean：端口在超时前就绪返回 $true。
    .NOTES
        --remote-allow-origins=* 是必需的：新版 Chromium 会拒绝未在
        白名单里的 Origin 发起的调试 WebSocket 连接。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$ProfileDir,
        [string]$StartUrl = 'about:blank'
    )

    if (-not (Test-Path $ProfileDir)) {
        New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
    }

    $arguments = @(
        "--remote-debugging-port=$Port"
        '--remote-allow-origins=*'
        "--user-data-dir=$ProfileDir"
        '--no-first-run'
        '--no-default-browser-check'
        '--start-maximized'
        $StartUrl
    )

    Start-Process -FilePath $Exe -ArgumentList $arguments | Out-Null

    # 冷启动可能较慢（首次建配置目录），最多等约 30 秒
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 750
        if (Get-CdpVersion -Port $Port) { return $true }
    }
    return $false
}

function Stop-DebugBrowser {
    <#
    .SYNOPSIS
        关闭使用指定配置目录启动的浏览器进程。
    .PARAMETER ProfileDir
        用于匹配命令行参数的配置目录。
    .NOTES
        靠命令行里是否含该目录来识别，因此不会影响使用者自己的浏览器窗口。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProfileDir)

    $needle = $ProfileDir.TrimEnd('\')
    try {
        Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe' OR Name='brave.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -and $_.CommandLine -like "*$needle*" } |
            ForEach-Object {
                try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { }
            }
    } catch { }
}

function Get-BrowserWindowHandle {
    <#
    .SYNOPSIS
        取浏览器真正的主窗口句柄。用于窗口布局与置前。
    .OUTPUTS
        IntPtr；找不到返回 [IntPtr]::Zero。
    .NOTES
        按窗口面积取最大的可见窗口 —— 浏览器进程里还有隐藏辅助窗口
        （坐标常在 -25600、尺寸极小），只看句柄大小会选错。
        枚举失败时退回"句柄最大的进程主窗口"。
    #>
    [CmdletBinding()]
    param()

    $procs = Get-Process -Name msedge, chrome, brave -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 }
    if (-not $procs) { return [IntPtr]::Zero }
    $best = $procs | Sort-Object { $_.MainWindowHandle.ToInt64() } | Select-Object -First 1
    return $best.MainWindowHandle
}

function Set-BrowserForeground {
    <#
    .SYNOPSIS
        把浏览器窗口置于前台。
    .NOTES
        超星的完成条件写明"观看时不可离开或将页面最小化"，
        因此默认保持前台。失败时静默忽略：抢不到焦点不该让主流程崩。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][IntPtr]$Handle)

    if ($Handle -eq [IntPtr]::Zero) { return }
    try { [Ccr.NativeMethods]::SetForegroundWindow($Handle) | Out-Null } catch { }
}

# SetForegroundWindow 的 P/Invoke 声明。
# 用 Add-Type 一次性编译；重复调用时 PowerShell 会复用已加载的类型。
# Win32 声明。用运行时 Add-Type（原因见 PageVisibility.psm1 里的说明）。
if (-not ('Ccr.NativeMethods' -as [type])) {
    try {
        Add-Type -Namespace Ccr -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr param);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT rect);
public delegate bool EnumProc(IntPtr h, IntPtr param);
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@ -ErrorAction Stop
    } catch {
        # 本文件不 import 其它模块，Write-CdpDiag 在这里不可用。
        # 用 Write-Verbose：默认不刷屏，加 -Verbose 能看到，不静默吞掉。
        Write-Verbose ('Win32 声明编译失败，浏览器窗口定位不可用: ' + $_.Exception.Message)
    }
}

