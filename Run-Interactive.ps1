<#
.SYNOPSIS
    超星学习通 · 自动连播工具（交互式）

.DESCRIPTION
    按"引导式"流程工作，每一步都有明确提示：

      1. 启动专用浏览器（独立配置目录，不影响你日常浏览器）
      2. 自动打开学习通登录页 —— 由你本人登录
      3. 提示你在该浏览器里打开要处理的课程「学生学习页面」
      4. 你按回车，工具校验页面并列出识别到的课程与待处理课节
      5. 你确认后开始自动连播

    这样做的好处：不需要工具去猜"哪门课""哪些课节已完成"，
    而是以你当前打开的页面为准。

.PARAMETER ConfigFile
    配置文件路径，默认同目录下 config.psd1。

.PARAMETER DebugPort
    浏览器调试端口（默认取配置文件）。

.PARAMETER MaxLessons
    本次最多处理几节。

.PARAMETER LessonIds
    只处理指定课节 id（逗号分隔）。

.PARAMETER SkipConfirm
    跳过"是否开始"的确认（用于自动化场景）。

.PARAMETER PollSeconds
    进度轮询间隔（秒）。

.PARAMETER NoForeground
    不把浏览器窗口抢到前台。

.EXAMPLE
    .\Run-Interactive.ps1
    交互式跑一遍：登录 -> 选课 -> 开始。

.NOTES
    退出码：0 正常；2 环境问题；3 读不到课程目录；4 参数/配置非法。
#>

[CmdletBinding()]
param(
    [string]$ConfigFile,
    [int]$DebugPort = 0,
    [int]$MaxLessons = 0,
    [string]$LessonIds,
    [int]$PollSeconds = 0,
    [switch]$SkipConfirm,
    [switch]$NoForeground
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$EXIT_OK = 0
$EXIT_ENV = 2
$EXIT_NO_DIRECTORY = 3
$EXIT_BAD_ARGS = 4

# ---------------------------------------------------------------- 加载库
$libManifest = Join-Path $PSScriptRoot 'lib\ChaoxingCourseRunner.psd1'
if (-not (Test-Path $libManifest)) {
    Write-Host "[错误] 找不到库清单: $libManifest" -ForegroundColor Red
    Write-Host "       目录没解压全！重新完整解压一次。" -ForegroundColor Red
    exit $EXIT_ENV
}
Import-Module $libManifest -Force -DisableNameChecking

# ---------------------------------------------------------------- 配置
$overrides = @{}
if ($DebugPort -gt 0) { $overrides.DebugPort = $DebugPort }
if ($MaxLessons -gt 0) { $overrides.MaxLessons = $MaxLessons }
if ($PollSeconds -gt 0) { $overrides.PollSeconds = $PollSeconds }
if ($LessonIds) { $overrides.LessonIds = $LessonIds }
if ($NoForeground) { $overrides.KeepForeground = $false }
if (-not $KeepForeground) { $overrides.KeepForeground = $false }

if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'config.psd1' }
try {
    $cfg = Get-RunnerSettings -ConfigPath $ConfigFile -Overrides $overrides
    $selectors = Import-CourseSelectors
} catch {
    Write-Host "[错误] 配置或选择器加载失败: $($_.Exception.Message)" -ForegroundColor Red
    exit $EXIT_BAD_ARGS
}

Set-CdpLogPath -Path $cfg.LogFile

# ---------------------------------------------------------------- 界面辅助
function Write-Banner {
    param([string]$Text)
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host ('  ' + $Text) -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}

function Write-Step {
    param([int]$No, [int]$Total, [string]$Text)
    Write-Host ("[步骤 $No/$Total] $Text") -ForegroundColor Yellow
}

function Write-Info { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Gray }
function Write-Good { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Green }
function Write-Warn2 { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Yellow }
function Write-Bad { param([string]$Text) Write-Host ('  ' + $Text) -ForegroundColor Red }

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    Write-RunnerLog -Message $Message -Path $cfg.LogFile -Level $Level
}

function Read-Confirm {
    param([string]$Prompt, [switch]$DefaultYes)
    while ($true) {
        Write-Host ('  ' + $Prompt) -ForegroundColor White -NoNewline
        Write-Host $(if ($DefaultYes) { ' [Y/n] ' } else { ' [y/N] ' }) -ForegroundColor DarkGray -NoNewline
        $ans = Read-Host
        if ([string]::IsNullOrWhiteSpace($ans)) { return [bool]$DefaultYes }
        if ($ans -match '^(?i)y(es)?$') { return $true }
        if ($ans -match '^(?i)n(o)?$') { return $false }
        Write-Warn2 '请输入 y 或 n'
    }
}

# ---------------------------------------------------------------- 找课程页
function Find-CoursePage {
    <#
        在调试端口的所有标签页里找"课程页"，只按 DOM 特征判定。

        不要退回 URL 匹配：
        登录页的 URL 是
          passport2.chaoxing.com/login?refer=https%3A%2F%2F...studentstudy...
        refer 参数里就含 "studentstudy"，用 URL 匹配会把登录页当成课程页，
        于是后面去做平台识别、必然失败，最后报出误导性的
        "认出了课程页，但识别不出平台版本"。
    #>
    param([Parameter(Mandatory)][int]$Port)

    foreach ($target in (Get-CdpTargets -Port $Port)) {
        if ($target.type -ne 'page') { continue }
        if ($target.url -match '^(devtools|chrome|edge)://') { continue }
        if ($target.url -match '^chrome-extension://') { continue }

        $probe = $null
        try {
            $probe = New-CdpSession -Page $target -Port $Port
            if (Test-CoursePage -Session $probe -Selectors $selectors) { return $target }
        } catch {
            Write-CdpDiag "探测标签页失败 ($($target.url)): $($_.Exception.Message)"
        } finally {
            Close-CdpSession -Session $probe
        }
    }
    return $null
}

function Wait-Until {
    <#
    .SYNOPSIS
        反复执行检测条件，直到成立或超时。
    .DESCRIPTION
        用于替代"让使用者按回车表示已完成"的做法 ——
        那种做法无法验证，使用者空按回车就会被当成成功。
        本函数直接读页面真实状态，只有条件真正成立才返回。
    .PARAMETER Test
        返回 $true/$false 的脚本块。
    .PARAMETER Message
        每次检测时显示的一行提示。
    .PARAMETER TimeoutSeconds
        最长时间；超时返回 $false。
    .OUTPUTS
        Boolean：条件是否成立。
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Test,
        [string]$Message = '等待中',
        [int]$TimeoutSeconds = 600,
        [string]$LaterMessage = '',
        [int]$LaterAfterSeconds = 20
    )

    $start = Get-Date
    $deadline = $start.AddSeconds($TimeoutSeconds)
    $tick = 0
    while ((Get-Date) -lt $deadline) {
        $tick++
        try {
            if (& $Test) { return $true }
        } catch {
            Write-CdpDiag ('Wait-Until 检测异常: ' + $_.Exception.Message)
        }

        # 两阶段提示：先中性等待，过一段时间仍未满足才换用更直白的说法。
        # 避免一上来就贴脸说"你还没做某事"。
        $elapsed = ((Get-Date) - $start).TotalSeconds
        $text = $Message
        if ($LaterMessage -and $elapsed -ge $LaterAfterSeconds) { $text = $LaterMessage }

        # 文本为空时完全不输出 —— 静默等待，连省略号也不画。
        if (-not [string]::IsNullOrEmpty($text)) {
            $dots = '.' * (($tick % 4) + 1)
            Write-ProgressLine -Text ('  ' + $text + $dots)
        }
        Start-Sleep -Seconds 3
    }
    Clear-ProgressLine
    return $false
}
function Get-AnyCourseTab {
    <#
        找出"与学习通有关"的标签页，用于在还没打开课程页时给出准确提示。
        .OUTPUTS
            @{ Found; Url; OnLoginPage }
    #>
    param([Parameter(Mandatory)][int]$Port)

    $info = @{ Found = $false; Url = ''; OnLoginPage = $false }
    foreach ($target in (Get-CdpTargets -Port $Port)) {
        if ($target.type -ne 'page') { continue }
        if ($target.url -notmatch 'chaoxing\.com') { continue }
        $info.Found = $true
        $info.Url = $target.url
        if ($target.url -match 'passport\d*\.chaoxing\.com') { $info.OnLoginPage = $true; break }
    }
    return $info
}

# ================================================================
#  主流程
# ================================================================

Clear-Host
# ---------------- 布局第一步：先把终端摆到右半屏 ----------------
# 此时浏览器还没启动，只能摆终端；先摆可以让启动信息落在正确位置。
if ($cfg.ArrangeWindows) {
    try {
        if (-not (Set-TerminalWindowPlacement -Side 'right')) {
            Write-Info '终端窗口没摆成（找不到窗口句柄），你可以手动拖一下'
        }
    } catch {
        Write-CdpDiag ('终端窗口摆放失败: ' + $_.Exception.Message)
    }
}

Write-Host '  ==========================================================' -ForegroundColor DarkCyan
Write-Host '   ██████╗██╗  ██╗     ██████╗ ██╗   ██╗███╗   ██╗███╗   ██╗███████╗██████╗' -ForegroundColor Magenta
Write-Host '  ██╔════╝╚██╗██╔╝     ██╔══██╗██║   ██║████╗  ██║████╗  ██║██╔════╝██╔══██╗' -ForegroundColor Magenta
Write-Host '  ██║      ╚███╔╝█████╗██████╔╝██║   ██║██╔██╗ ██║██╔██╗ ██║█████╗  ██████╔╝' -ForegroundColor Magenta
Write-Host '  ██║      ██╔██╗╚════╝██╔══██╗██║   ██║██║╚██╗██║██║╚██╗██║██╔══╝  ██╔══██╗' -ForegroundColor Magenta
Write-Host '  ╚██████╗██╔╝ ██╗     ██║  ██║╚██████╔╝██║ ╚████║██║ ╚████║███████╗██║  ██║' -ForegroundColor Magenta
Write-Host '   ╚═════╝╚═╝  ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝' -ForegroundColor Magenta
Write-Host '  超星学习通 · 自动连播工具' -ForegroundColor Cyan
Write-Host '  by liusida <1102271746@qq.com>   github.com/2008liusida/chaoxing-course-runner' -ForegroundColor White
Write-Host '  ==========================================================' -ForegroundColor DarkCyan
Write-Info ('工具目录: ' + $cfg.Root)
Write-Info ('版本 2.1.0  日志: ' + $cfg.LogFile)
Write-Host '  【免责声明】' -ForegroundColor Yellow
Write-Host '  本工具仅供学习交流与个人学习进度规划使用，严禁用于恶意刷课、代学代刷、' -ForegroundColor Yellow
Write-Host '  批量账号操作等违规作弊行为。请遵守所在平台与学校的相关规定。' -ForegroundColor Yellow
Write-Host '  使用者应自行判断使用场景是否合规，违规使用所产生的一切后果由使用者自行承担。' -ForegroundColor Yellow
Write-Host '  本软件按原样提供，作者不对使用结果、账号状态或平台处罚承担任何责任。' -ForegroundColor Yellow
Write-Host '  本工具按 1 倍速真实播放，不代答测验与作业，不模拟点击、不做任何反检测处理。' -ForegroundColor DarkGray

Write-Log '=== 交互式运行开始 ==='

# Invoke-Lesson 需要注入日志出口
$logBlock = { param($Message, $Level = 'INFO', [switch]$Transient, [switch]$FileOnly) if ($FileOnly) { Write-RunnerLog -Message $Message -Level $Level -Path $cfg.LogFile -FileOnly } elseif ($Transient) { Write-RunnerLog -Message $Message -Level $Level -Transient } else { Write-Log -Message $Message -Level $Level } }

# ---------------- 步骤 1：准备浏览器 ----------------
# ---------------- 显示缓存占用（只报告，不清理） ----------------
# 清理请双击目录里的 ClearCache.bat
$cacheDir = Join-Path $PSScriptRoot 'browser-profile'
if (Test-Path $cacheDir) {
    $cacheBytes = (Get-ChildItem $cacheDir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object Length -Sum).Sum
    if ($null -eq $cacheBytes) { $cacheBytes = 0 }
    $cacheText = if ($cacheBytes -ge 1MB) {
        ([math]::Round($cacheBytes / 1MB, 1)).ToString() + ' MB'
    } elseif ($cacheBytes -ge 1KB) {
        ([math]::Round($cacheBytes / 1KB, 1)).ToString() + ' KB'
    } else {
        ([int]$cacheBytes).ToString() + ' B'
    }
    Write-Info ('浏览器缓存: ' + $cacheText + '（清理请双击 ClearCache.bat）')
}

Write-Step 1 4 '准备浏览器'

$version = Get-CdpVersion -Port $cfg.DebugPort
if ($version) {
    Write-Good ('调试端口 ' + $cfg.DebugPort + ' 已有实例，直接复用')
} else {
    $exe = Find-BrowserExe -Preferred $cfg.Browser
    if (-not $exe) {
        Write-Bad '没有 Edge 也没有 Chrome，先装一个！'
        exit $EXIT_ENV
    }
    Write-Info ('正在启动: ' + $exe)
    Write-Info ('独立配置目录: ' + $cfg.ProfileDir)
    if (-not (Start-DebugBrowser -Exe $exe -Port $cfg.DebugPort -ProfileDir $cfg.ProfileDir -StartUrl $cfg.StartUrl)) {
        Write-Bad ('浏览器已启动，但调试端口 ' + $cfg.DebugPort + ' 连不上。')
        Write-Bad '可能被安全软件拦截，或在 config.psd1 里换一个端口再试。'
        exit $EXIT_ENV
    }
    $version = Get-CdpVersion -Port $cfg.DebugPort
}
Write-Good ('浏览器就绪: ' + $version.Browser)

# ---------------- 布局第二步：浏览器已就绪，摆到左半屏 ----------------
# 浏览器必须等启动完才有窗口句柄，所以放在这里。
# 用带校验的版本：浏览器会异步恢复上次的窗口状态，可能覆盖掉布局。
if ($cfg.ArrangeWindows) {
    try {
        $layoutBrowser = Get-BrowserWindowHandle
        $lay = Arrange-WindowsVerified -BrowserHandle $layoutBrowser -BrowserSide 'left'
        if (-not $lay.Ok) {
            Write-Info ('窗口没摆到位（试了 ' + $lay.Attempts + ' 轮），你可以手动拖一下')
        }
    } catch {
        Write-CdpDiag ('浏览器布局失败: ' + $_.Exception.Message)
    }
}

# ---------------- 步骤 2：等待用户登录并确认 ----------------
Write-Step 2 4 '登录学习通'

function Get-LoginState {
    <#
    .SYNOPSIS
        判断浏览器当前处于哪一步。
    .DESCRIPTION
        返回三种状态：
          'no-page' 没有学习通页面（刚启动、还在跳转、或标签页是空白）
          'login'   停在登录页
          'ready'   停在真正的学习通页面，且不在登录页

        为什么需要它：不能用"没停在登录页"来判定已登录 ——
        浏览器刚启动时是空白页，那时"没停在登录页"也成立，
        会被误判成已登录。只有 'ready' 才是"确实登上了"。
    .OUTPUTS
        String：'no-page' | 'login' | 'ready'
    #>
    param([Parameter(Mandatory)][int]$Port)

    $tab = Get-AnyCourseTab -Port $Port
    if (-not $tab.Found) { return 'no-page' }
    if ($tab.OnLoginPage) { return 'login' }
    if ($tab.Url -match 'passport\d*\.chaoxing\.com') { return 'login' }
    if ($tab.Url -match '/login') { return 'login' }
    return 'ready'
}

function Get-CanvasInfo {
    <#
        判断浏览器里"登录了没有"。
        逐个标签页检查是否停在登录页 —— 不能依赖"找到课程页"，
        因为登录页本身不是课程页，那样会被误判成"已登录"。
    .OUTPUTS
        @{ OnLoginPage = <bool>; AnyChaoxing = <bool>; Url = <string> }
    #>
    $info = @{ OnLoginPage = $false; AnyChaoxing = $false; Url = '' }

    foreach ($target in (Get-CdpTargets -Port $cfg.DebugPort)) {
        if ($target.type -ne 'page') { continue }
        if ($target.url -match '^(chrome-extension|devtools|edge)://') { continue }

        $isChaoxing = ($target.url -match 'chaoxing\.com')
        if ($isChaoxing) { $info.AnyChaoxing = $true }
        if ($target.url -match 'passport\d*\.chaoxing\.com') {
            $info.OnLoginPage = $true
            $info.Url = $target.url
            break
        }

        # 地址不像登录页时，再读一次 DOM 确认（有的登录页不换域）
        $s = $null
        try {
            $s = New-CdpSession -Page $target -Port $cfg.DebugPort
            $r = Invoke-CdpJs -Session $s -Expression 'JSON.stringify({url:location.href,hasPwd:!!document.querySelector("input[type=password]")})'
            if (-not $r.Error -and $r.Value) {
                $o = $r.Value | ConvertFrom-Json
                $u = [string]$o.url
                if ($u -match 'chaoxing\.com') { $info.AnyChaoxing = $true }
                if ([bool]$o.hasPwd -or $u -match 'passport\d*\.chaoxing\.com') {
                    $info.OnLoginPage = $true
                    $info.Url = $u
                    break
                }
            }
        } catch {
            Write-CdpDiag ('探测登录页失败: ' + $_.Exception.Message)
        } finally {
            Close-CdpSession -Session $s
        }
    }
    return $info
}

$canvas = Get-CanvasInfo
if ($canvas.OnLoginPage) {
    Write-Info '登录页给你开好了，去登陆吧~'

    # 自动检测，一直等 —— 不催促、不提示，确认登上了才继续。
    # 判据是"确认停在真正的学习通页面"，而不是"没停在登录页"：
    # 后者在浏览器刚启动（空白页）时就成立，会误报已登录。
    [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test {
        'ready' -eq (Get-LoginState -Port $cfg.DebugPort)
    })
    Clear-ProgressLine
    Write-Good '行'
}

# ---------------- 步骤 3：询问并等待用户打开目标课程 ----------------
Write-Step 3 4 '打开目标课程'

Write-Host '  ┌──────────────────────────────────────────────────────────┐' -ForegroundColor Cyan
Write-Host '  │  现在去浏览器里打开你要刷的课程                          │' -ForegroundColor Cyan
Write-Host '  │                                                          │' -ForegroundColor Cyan
Write-Host '  │  要打开的是「学生学习页面」：                            │' -ForegroundColor Cyan
Write-Host '  │  左边有课程目录、右边是视频播放器的那个页面              │' -ForegroundColor Cyan
Write-Host '  │                                                          │' -ForegroundColor Cyan
Write-Host '  │  不要停在「个人空间」首页，工具认不出来                  │' -ForegroundColor Cyan
Write-Host '  └──────────────────────────────────────────────────────────┘' -ForegroundColor Cyan

# 自动轮询等待课程页出现，不需要使用者按键。
# 只有真正检测到课程页才继续，避免"空按回车被当成已完成"。
[void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test {
    $null -ne (Find-CoursePage -Port $cfg.DebugPort)
})
Clear-ProgressLine
Write-Good '看到了，开始查页面……'

# 校验页面：允许重试
# 注意：这里必须做平台版本识别（Resolve-Platform），
# 并把 DirContextId 传给所有读取函数 ——
# mooc2 版学习通的目录结构与顶层输入框位置都不同，缺了这一步会读不到目录。
$lessonList = @()
$currentId = ''
$session = $null
$plat = $null
$attempt = 0
while ($attempt -lt 5) {
    $attempt++
    $page = Find-CoursePage -Port $cfg.DebugPort

    # 找不到课程页时，先判断"卡在哪一步"，给出准确指引。
    # 不要笼统报"没有检测到课程页"—— 那会让已经登录的人以为自己没登录。
    if (-not $page) {
        $tab = Get-AnyCourseTab -Port $cfg.DebugPort
        if ($tab.OnLoginPage) {
            Write-Info '页面还在登录页，继续等你……'
            [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test {
                'ready' -eq (Get-LoginState -Port $cfg.DebugPort)
            })
            Clear-ProgressLine
        } elseif ($tab.Found) {
            Write-Bad '登是登上了，可你没打开课程页啊！'
            Write-Info ('当前页面: ' + $tab.Url.Substring(0, [Math]::Min(90, $tab.Url.Length)))
            Write-Info '点进你的课程，再点左侧目录里随便一节。要找的是「左边目录右边视频」那个页面。'
            [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test { $null -ne (Find-CoursePage -Port $cfg.DebugPort) })
            Clear-ProgressLine
        } else {
            Write-Bad '浏览器里压根没有学习通页面！'
            Write-Info '先去登录学习通，再打开课程的「学生学习页面」。'
            [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test { (Get-AnyCourseTab -Port $cfg.DebugPort).Found })
            Clear-ProgressLine
        }
        continue
    }

    $session = New-CdpSession -Page $page -Port $cfg.DebugPort

    # 先识别平台版本 —— 拿到合并后的选择器，后续所有判定都用它。
    # 顺序很重要：Test-LoggedIn / Test-CoursePage 需要 common 块里的
    # PageFingerprints，传原始表会取不到值，判定会永远失败。
    $plat = Resolve-Platform -Session $session -RawSelectors $selectors
    Write-Info ('平台版本: ' + $plat.Version + $(if ($plat.DirContextId -gt 0) { '（目录在 iframe 内）' } else { '' }))

    if (-not (Test-LoggedIn -Session $session -Selectors $plat.Selectors)) {
        Close-CdpSession -Session $session
        $session = $null
        Write-Bad '这页面不对！要么没登录，要么登录过期了。'
        [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test { (Get-AnyCourseTab -Port $cfg.DebugPort).Found })
        Clear-ProgressLine
        continue
    }

    if ($plat.Version -eq '') {
        Close-CdpSession -Session $session
        $session = $null
        Write-Bad '页面是课程页，但版本我不认识。学习通大概又改版了。'
        Write-Info ('页面地址: ' + $page.url)
        Write-Info '可以在 config.psd1 里换一个端口后重试。'
        [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test { (Get-AnyCourseTab -Port $cfg.DebugPort).Found })
        Clear-ProgressLine
        continue
    }

    $lessonList = @(Get-LessonList -Session $session -Selectors $plat.Selectors -DirContextId $plat.DirContextId)
    $currentId = Get-CurrentLessonId -Session $session -Selectors $plat.Selectors -DirContextId $plat.DirContextId

    if ($lessonList.Count -eq 0) {
        Close-CdpSession -Session $session
        $session = $null
        Write-Bad '页面认出来了，但读不到课程目录。'
        Write-Info '要么页面没加载完，要么这门课根本没目录。'
        Write-Info ('页面地址: ' + $page.url)
        [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test { (Get-AnyCourseTab -Port $cfg.DebugPort).Found })
        Clear-ProgressLine
        continue
    }
    break
}

if ($lessonList.Count -eq 0 -or $null -eq $session) {
    Write-Bad '试了好几次还是读不到目录，不干了。'
    exit $EXIT_NO_DIRECTORY
}

# ---------------- 步骤 4：确认并开始 ----------------
Write-Step 4 4 '确认并开始'

$courseId = Get-CourseId -Session $session -Selectors $plat.Selectors -DirContextId $plat.DirContextId
$clazzId = Get-ClazzId -Session $session -Selectors $plat.Selectors -DirContextId $plat.DirContextId
$lessonEntries = @($lessonList | Where-Object { -not $_.Unfinished -or $true })  # 目录全量
$toProcess = @($lessonList | Where-Object { $_.Unfinished })
if ([int]$cfg.MaxLessons -gt 0 -and $toProcess.Count -gt [int]$cfg.MaxLessons) {
    $toProcess = $toProcess[0..([int]$cfg.MaxLessons - 1)]
}

Write-Good ('课程 id: ' + $courseId + '   班级 id: ' + $clazzId)
Write-Info ('目录共识别到 ' + $lessonList.Count + ' 个条目（含章节标题）')
Write-Info ('当前所在: ' + $currentId)
Write-Host ('  待处理课节 ' + $toProcess.Count + ' 个:') -ForegroundColor White
$showCount = [Math]::Min(15, $toProcess.Count)
for ($i = 0; $i -lt $showCount; $i++) {
    $l = $toProcess[$i]
    $title = $l.Title
    if ($title.Length -gt 42) { $title = $title.Substring(0, 42) + '…' }
    Write-Host ('    ' + ($i + 1).ToString().PadLeft(3) + '. ' + $title) -ForegroundColor Gray
}
if ($toProcess.Count -gt $showCount) {
    Write-Host ('    … 另外 ' + ($toProcess.Count - $showCount) + ' 个') -ForegroundColor DarkGray
}

if ($toProcess.Count -eq 0) {
    Write-Good '没了，全刷完了！'
    Close-CdpSession -Session $session
    exit $EXIT_OK
}

Write-Info '说明：开始后我自己一节一节往下播，不用你管。'
Write-Info '      想停就按 Ctrl+C，刷完的不会重刷。'
Write-Info '      别把浏览器最小化！页面看不见视频就加载不了。'

$go = $true
if (-not $SkipConfirm) {
    $go = Read-Confirm -Prompt '现在开始？' -DefaultYes
}
if (-not $go) {
    Write-Warn2 '已取消。'
    Close-CdpSession -Session $session
    exit $EXIT_OK
}

# ---------------- 开始处理（无人值守）----------------
Write-Banner '开始自动连播'
Write-Info '你可以走了，我自己往下播。'
Write-Info '想停：Ctrl+C，或者直接关窗口。刷完的不重刷。'
Write-Log ('用户确认开始，待处理 ' + $toProcess.Count + ' 节')

# 无人值守的两个关键约束：
#   1) MaxWaitMinutesPerLesson —— 单节最长等待。视频再长也有结尾，
#      超时说明卡住了，宁可跳过也不要在这里耗一整夜。
#   2) MaxTotalMinutes —— 整批任务的总时间上限，防止意外跑到天亮。
# 用户若在 config.psd1 里显式写了更小的值，尊重用户设置。
$unattended = [pscustomobject]@{
    Browser                 = $cfg.Browser
    DebugPort               = $cfg.DebugPort
    ProfileDir              = $cfg.ProfileDir
    StartUrl                = $cfg.StartUrl
    SwitchMode              = $cfg.SwitchMode
    LessonIds               = $cfg.LessonIds
    MaxLessons              = $cfg.MaxLessons
    MaxReplayPerLesson      = $cfg.MaxReplayPerLesson
    MaxWaitMinutesPerLesson = [Math]::Min([double]$cfg.MaxWaitMinutesPerLesson, 12)
    PlaybackRate            = $cfg.PlaybackRate
    PollSeconds             = $cfg.PollSeconds
    KeepForeground          = $cfg.KeepForeground
    LogFile                 = $cfg.LogFile
    Root                    = $cfg.Root
}
Write-Info ('单节最长等待: ' + $unattended.MaxWaitMinutesPerLesson + ' 分钟（超时则跳过，继续下一节）')

$windowHandle = Get-BrowserWindowHandle
$doneCount = 0
$consecutiveFail = 0
$failedIds = New-Object System.Collections.Generic.List[string]
$startedAt = Get-Date
$idx = 0

foreach ($lesson in $toProcess) {
    $idx++
    Write-Host ('──── [' + $idx + '/' + $toProcess.Count + '] ' + $lesson.Title) -ForegroundColor Cyan

    $ok = $false
    try {
        $ok = Invoke-Lesson -Session $session -Lesson $lesson -Selectors $plat.Selectors `
            -Settings $unattended -WindowHandle $windowHandle -Log $logBlock
    } catch {
        Write-Bad ('处理时异常: ' + $_.Exception.Message)
        Write-CdpDiag ('Invoke-Lesson 异常: ' + $_.Exception.ToString())
    }

    if ($ok) {
        $doneCount++
        $consecutiveFail = 0
        Write-Good ('完成  累计 ' + $doneCount + ' 节  已用时 ' + [int]((Get-Date) - $startedAt).TotalMinutes + ' 分钟')
    } else {
        $failedIds.Add($lesson.Id) | Out-Null
        $consecutiveFail++
        Write-Warn2 '这节没过，跳了。'

        # 连续失败通常意味着环境出了问题（断网 / 登录过期 / 浏览器被关），
        # 而不是这些课节本身有问题。此时继续跑只会白白等待。
        # 所以这里果断停下来，把问题交回使用者。
        if ($consecutiveFail -ge 3) {
            Write-Bad ('连续 ' + $consecutiveFail + ' 节失败，判定为环境异常，停止运行。')
            Write-Info '常见原因：'
            Write-Info '  · 网络断开或代理不可用'
            Write-Info '  · 学习通登录已过期（重新跑 first-run-login.bat）'
            Write-Info '  · 浏览器窗口被关闭'
            Write-Info '弄好之后重新双击 Run-Interactive.bat，接着刷，刷完的不重刷。'
            Write-Log ('连续 ' + $consecutiveFail + ' 节失败，提前停止') 'ERROR'
            break
        }
    }

    # 每 5 节报一次总体进度，便于回头看日志
    if ($idx % 5 -eq 0) {
        Write-Log ('进度 ' + $idx + '/' + $toProcess.Count + '：完成 ' + $doneCount + '，未完成 ' + $failedIds.Count)
    }

    # 会话可能因页面导航失效，定期重建，避免后续课节全部失败
    if ($idx % 10 -eq 0) {
        Write-Info '重连一下……'
        try { Close-CdpSession -Session $session } catch { }
        $page = Find-CoursePage -Port $cfg.DebugPort
        if ($page) {
            $session = New-CdpSession -Page $page -Port $cfg.DebugPort
            $plat = Resolve-Platform -Session $session -RawSelectors $selectors
            Write-Info ('  重建完成，平台版本 ' + $plat.Version)
        } else {
            Write-Warn2 '  找不到课程页了，后面可能要出事'
        }
    }

    # 总时长保护
    if (((Get-Date) - $startedAt).TotalMinutes -gt 600) {
        Write-Warn2 '跑了 10 小时了，收工。'
        break
    }
}

# ---------------- 汇总 ----------------
Write-Banner '运行结束'
$elapsed = (Get-Date) - $startedAt
Write-Info ('总用时:   ' + [int]$elapsed.TotalHours + ' 小时 ' + $elapsed.Minutes + ' 分钟')
Write-Info ('本次完成: ' + $doneCount + ' 节')
Write-Info ('未完成:   ' + $failedIds.Count + ' 节')
if ($failedIds.Count -gt 0) {
    Write-Warn2 ('未完成的课节 id: ' + (@($failedIds) -join ', '))
    Write-Info  '（多半是要求 100% 时长，或者那节是测验/作业。自己去看一眼）'
}

try {
    $remaining = @(Get-LessonList -Session $session -Selectors $plat.Selectors -DirContextId $plat.DirContextId |
        Where-Object { $_.Unfinished })
    Write-Info ('目录中仍标记未完成: ' + $remaining.Count + ' 节')
} catch {
    Write-Warn2 '最后查目录失败了，不过刷完的都在。'
}

Write-Good ('日志: ' + $cfg.LogFile)
Write-Log ('=== 交互式运行结束：完成 ' + $doneCount + '，未完成 ' + $failedIds.Count + '，用时 ' + [int]$elapsed.TotalMinutes + ' 分钟 ===')

Close-CdpSession -Session $session
exit $EXIT_OK