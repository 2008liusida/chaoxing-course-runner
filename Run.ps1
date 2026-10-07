<#
.SYNOPSIS
    超星学习通 · 自动连播工具

.DESCRIPTION
    自动扫描课程目录里"未完成"的课节，逐个播放视频，播完自动进入下一节，
    直到全部完成。

    单节课的驱动流程：
        切课 -> 等待生效 -> 确认有视频 -> 播放 -> 轮询到播完
             -> 等平台登记完成 -> 未登记则重播一次 -> 仍失败则跳过并记录

    判定依据全部来自 DOM（id / class），不依赖界面文字 ——
    因为学习通给课节标题套了反爬字体，文字取出来是乱码。
    详细契约见 lib\Selectors.psd1。

.PARAMETER ConfigFile
    配置文件路径，默认同目录下 config.psd1。

.PARAMETER LessonIds
    只处理这些课节 id（逗号分隔）。默认处理目录里所有未完成课节。

.PARAMETER MaxLessons
    本次最多处理几节。

.PARAMETER DebugPort
    浏览器调试端口，覆盖配置文件。

.PARAMETER PollSeconds
    进度轮询间隔（秒），覆盖配置文件。

.PARAMETER Browser
    浏览器名（msedge / chrome），覆盖配置文件。

.PARAMETER ProfileDir
    浏览器用户配置目录，覆盖配置文件。

.PARAMETER StartUrl
    启动浏览器时打开的页面，覆盖配置文件。

.PARAMETER NoForeground
    不把浏览器窗口抢到前台。默认保持前台，因为超星的完成条件
    写明"观看时不可离开或将页面最小化"。需要在跑的同时用电脑时用这个开关。

.PARAMETER LaunchOnly
    只启动浏览器并给出登录指引，不播放。
    日常不需要它 —— 双击 Start.bat 会自动启动浏览器并打开登录页。

.PARAMETER DryRun
    只列出本次会处理哪些课节，不播放。

.PARAMETER NoLaunch
    不自动启动浏览器（要求调试端口上已有实例）。

.PARAMETER StopBrowserWhenDone
    全部跑完后关闭本工具启动的浏览器实例。

.EXAMPLE
    .\Run.ps1 -LaunchOnly
    只把浏览器开起来（例如想先登录、稍后再跑）。

.EXAMPLE
    .\Run.ps1
    自动播完所有未完成课节。

.EXAMPLE
    .\Run.ps1 -DryRun
    先看看会处理哪些课节。

.EXAMPLE
    .\Run.ps1 -LessonIds 1222994220,1222994221 -MaxLessons 2
    只处理指定的两节。

.NOTES
    退出码：0 正常结束；2 环境/依赖问题；3 读不到课程目录；4 参数非法。
    许可证：PolyForm Noncommercial 1.0.0，详见 LICENSE 与 NOTICE。
#>

[CmdletBinding()]
param(
    [string]$ConfigFile,
    [string]$LessonIds,
    [int]$MaxLessons = 0,
    [int]$DebugPort = 0,
    [int]$PollSeconds = 0,
    [string]$Browser,
    [string]$ProfileDir,
    [string]$StartUrl,
    [switch]$NoForeground,
    [switch]$LaunchOnly,
    [switch]$DryRun,
    [switch]$NoLaunch,
    [switch]$StopBrowserWhenDone
)

$ErrorActionPreference = 'Stop'
# 让中文在 Windows PowerShell 5.1 的控制台里也能正常显示
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

# ---------------------------------------------------------------- 退出码
$EXIT_OK = 0
$EXIT_ENV = 2
$EXIT_NO_DIRECTORY = 3
$EXIT_BAD_ARGS = 4

# ---------------------------------------------------------------- 加载库
$libManifest = Join-Path $PSScriptRoot 'lib\ChaoxingCourseRunner.psd1'
if (-not (Test-Path $libManifest)) { throw "找不到库清单: $libManifest" }
Import-Module $libManifest -Force -DisableNameChecking

# ---------------------------------------------------------------- 配置
$overrides = @{}
if ($PSBoundParameters.ContainsKey('LessonIds')) { $overrides.LessonIds = $LessonIds }
if ($MaxLessons -gt 0) { $overrides.MaxLessons = $MaxLessons }
if ($DebugPort -gt 0) { $overrides.DebugPort = $DebugPort }
if ($PollSeconds -gt 0) { $overrides.PollSeconds = $PollSeconds }
if ($Browser) { $overrides.Browser = $Browser }
if ($ProfileDir) { $overrides.ProfileDir = $ProfileDir }
if ($StartUrl) { $overrides.StartUrl = $StartUrl }
if ($NoForeground) { $overrides.KeepForeground = $false }

if (-not $ConfigFile) { $ConfigFile = Join-Path $PSScriptRoot 'config.psd1' }

try {
    $cfg = Get-RunnerSettings -ConfigPath $ConfigFile -Overrides $overrides
    $dirCtx = 0
$selectors = Import-CourseSelectors
} catch {
    Write-Host "[错误] 配置或选择器加载失败: $($_.Exception.Message)" -ForegroundColor Red
    exit $EXIT_BAD_ARGS
}

Set-CdpLogPath -Path $cfg.LogFile

function Write-Log {
    <#
    .SYNOPSIS
        统一日志出口（同时写控制台与日志文件）。
    #>
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [Parameter(Position = 1)][string]$Level = 'INFO',
        [switch]$FileOnly
    )
    if ($FileOnly) {
        Write-RunnerLog -Message $Message -Path $cfg.LogFile -Level $Level -FileOnly
    } else {
        Write-RunnerLog -Message $Message -Path $cfg.LogFile -Level $Level
    }
}


# ---------------------------------------------------------------- 辅助函数

function Open-CourseList {
    <#
    .SYNOPSIS
        让浏览器打开学习通课程列表页，方便用户挑课程。
    .NOTES
        只导航到课程列表，不代替用户进入具体课程 ——
        工具无法知道用户要刷哪门课。
    #>
    param([Parameter(Mandatory)][int]$Port)

    $targetUrl = 'https://i.mooc.chaoxing.com/space/index'
    foreach ($target in (Get-CdpTargets -Port $Port)) {
        if ($target.type -ne 'page') { continue }
        if ($target.url -match '^(chrome-extension|devtools|edge)://') { continue }
        $s = $null
        try {
            $s = New-CdpSession -Page $target -Port $Port
            Send-Cdp -Session $s -Method 'Page.navigate' -Params @{ url = $targetUrl } -FireAndForget | Out-Null
            return $true
        } catch {
            Write-CdpDiag ("导航到课程列表失败: " + $_.Exception.Message)
        } finally {
            Close-CdpSession -Session $s
        }
    }
    return $false
}

function Wait-UserLogin {
    <#
    .SYNOPSIS
        在浏览器停于登录页时，等待用户完成登录，并回读确认。
    .DESCRIPTION
        流程：
          1. 确保浏览器打开的是学习通登录页（供用户登录）
          2. 明确提示用户去登录
          3. 用户按回车后回读确认是否已离开登录页
          4. 已登录则自动跳到课程列表页，方便用户挑课程
    .OUTPUTS
        Boolean：$true 表示确认已登录。
    #>
    param([Parameter(Mandatory)][int]$Port)

    $tab = Get-AnyCourseTab -Port $Port
    if (-not $tab.OnLoginPage) {
        # 不在登录页，但如果连学习通页面都没有，就主动打开登录页
        if (-not $tab.Found) {
            Write-Log '浏览器里没有学习通页面，正在打开登录页…'
            foreach ($target in (Get-CdpTargets -Port $Port)) {
                if ($target.type -ne 'page') { continue }
                if ($target.url -match '^(chrome-extension|devtools|edge)://') { continue }
                $s = $null
                try {
                    $s = New-CdpSession -Page $target -Port $Port
                    Send-Cdp -Session $s -Method 'Page.navigate' -Params @{ url = 'https://passport2.chaoxing.com/login' } -FireAndForget | Out-Null
                } catch { } finally { Close-CdpSession -Session $s }
                break
            }
        } else {
            return $true
        }
    }

    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  去登录学习通！' -ForegroundColor Yellow
    Write-Host '============================================================' -ForegroundColor Yellow
    Write-Host '  登录页开好了，去登陆吧~' -ForegroundColor White
    Write-Host ''

    # 自动检测，一直等 —— 不催促、不提示，确认登上了才继续。
    # 判据是"确认停在真正的学习通页面"，而不是"没停在登录页"：
    # 后者在浏览器刚启动（空白页）时就成立，会误报已登录。
    [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test {
        'ready' -eq (Get-LoginState -Port $Port)
    })
    Clear-ProgressLine
    Write-Host '  行' -ForegroundColor Green
    Write-Host '  给你开课程列表……' -ForegroundColor Gray
    if (Open-CourseList -Port $Port) {
        Write-Host '  去点进你要刷的课，进「学生学习页面」' -ForegroundColor White
        Write-Host '  （左边目录、右边视频那个页面）' -ForegroundColor Gray
        # 同样只认正面确认：必须真的找到课程页。
        [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test {
            $null -ne (Find-CoursePage -Port $Port)
        })
        Clear-ProgressLine
    }
    return $true
}
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
        会被误判成已登录。
        只有 'ready' 才是"确实登上了"。
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

function Find-CoursePage {
    <#
    .SYNOPSIS
        在调试端口的所有标签页里找出"课程页"，只按 DOM 特征判定。
    .NOTES
        不要退回 URL 匹配：
        登录页 URL 形如
          passport2.chaoxing.com/login?refer=https%3A%2F%2F...studentstudy...
        refer 参数里就含 "studentstudy"，用 URL 匹配会把登录页当成课程页，
        后面必然做不成平台识别，还会报出误导性的错误。
        宁可返回"没找到"，也不要返回一个错的页面。
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

function Get-AnyCourseTab {
    <#
    .SYNOPSIS
        找出与学习通有关的标签页，用于在找不到课程页时给出准确提示。
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

function Wait-Until {
    <#
    .SYNOPSIS
        反复执行检测条件，直到成立或超时。
    .DESCRIPTION
        用于替代"让使用者按回车表示已完成"的做法 —— 那种做法无法验证，
        使用者空按回车就会被当成成功。本函数直接读页面真实状态。
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


function Build-LessonQueue {
    <#
    .SYNOPSIS
        决定本次要处理哪些课节。
    .OUTPUTS
        对象数组，元素含 Id / Title / Unfinished。
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][int]$Limit
    )

    $all = @(Get-LessonList -Session $Session -Selectors $selectors -DirContextId $dirCtx)
    if ($all.Count -eq 0) { return @() }

    $queue = @()
    if ($cfg.LessonIds) {
        $wanted = @($cfg.LessonIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        foreach ($id in $wanted) {
            $hit = $all | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            if ($hit) { $queue += $hit }
            else { Write-Log "指定课节不在当前目录里，忽略: $id" 'WARN' }
        }
    } else {
        $queue = @($all | Where-Object { $_.Unfinished })
    }

    if ($Limit -gt 0 -and $queue.Count -gt $Limit) { $queue = $queue[0..($Limit - 1)] }
    return $queue
}

# 课节处理逻辑由 lib\LessonRunner.psm1 提供。
# 两个入口共用同一份实现，避免各自演化导致行为不一致。
# 调用时通过 -Log 注入本脚本的日志出口。

# ---------------------------------------------------------------- 主流程

Write-Log '=== 超星学习通 · 自动连播工具 启动 ===' 'INFO' -FileOnly
try { Clear-Host } catch { }
# ---------------- 布局第一步：先把终端摆到右半屏 ----------------
# 此时浏览器还没启动，只能摆终端。
# 先摆的好处是：接下来打印的启动信息立刻落在正确位置，不会先左后右地跳。
if ($cfg.ArrangeWindows) {
    try {
        if (-not (Set-TerminalWindowPlacement -Side 'right')) {
            Write-Log '终端窗口没摆成（找不到窗口句柄），你可以手动拖一下' 'WARN'
        }
    } catch {
        Write-CdpDiag ('终端窗口摆放失败: ' + $_.Exception.Message)
    }
}

Write-Log '=========================================================='
Write-Log ' ██████╗██╗  ██╗     ██████╗ ██╗   ██╗███╗   ██╗███╗   ██╗███████╗██████╗' 'OK'
Write-Log '██╔════╝╚██╗██╔╝     ██╔══██╗██║   ██║████╗  ██║████╗  ██║██╔════╝██╔══██╗' 'OK'
Write-Log '██║      ╚███╔╝█████╗██████╔╝██║   ██║██╔██╗ ██║██╔██╗ ██║█████╗  ██████╔╝' 'OK'
Write-Log '██║      ██╔██╗╚════╝██╔══██╗██║   ██║██║╚██╗██║██║╚██╗██║██╔══╝  ██╔══██╗' 'OK'
Write-Log '╚██████╗██╔╝ ██╗     ██║  ██║╚██████╔╝██║ ╚████║██║ ╚████║███████╗██║  ██║' 'OK'
Write-Log ' ╚═════╝╚═╝  ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝' 'OK'
Write-Log '超星学习通 · 自动连播工具'
Write-Log 'by liusida <1102271746@qq.com>   github.com/2008liusida/chaoxing-course-runner'
Write-Log '=========================================================='
Write-Log "版本 2.1.0   工具目录: $($cfg.Root)"
Write-Log '【免责声明】' 'WARN'
Write-Log '本工具仅供学习交流与个人学习进度规划使用，严禁用于恶意刷课、代学代刷、' 'WARN'
Write-Log '批量账号操作等违规作弊行为。请遵守所在平台与学校的相关规定。' 'WARN'
Write-Log '使用者应自行判断使用场景是否合规，违规使用所产生的一切后果由使用者自行承担。' 'WARN'
Write-Log '本软件按原样提供，作者不对使用结果、账号状态或平台处罚承担任何责任。' 'WARN'
Write-Log '本工具按 1 倍速真实播放，不代答测验与作业，不模拟点击、不做任何反检测处理。'
Write-Log "浏览器配置目录: $($cfg.ProfileDir)"

# ---- 0. 显示缓存占用（只报告，不清理） ----
$cacheDir = $cfg.ProfileDir
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
    Write-Log ('浏览器缓存: ' + $cacheText + '（清理请双击 ClearCache.bat）')
}

# ---- 1. 确保有一个带调试端口的浏览器 ----
$version = Get-CdpVersion -Port $cfg.DebugPort
if ($version) {
    Write-Log "调试端口 $($cfg.DebugPort) 已有实例，直接复用（不新开窗口）"
} else {
    if ($NoLaunch) {
        Write-Log "调试端口 $($cfg.DebugPort) 不可用，且指定了 -NoLaunch" 'ERROR'
        exit $EXIT_ENV
    }
    $exe = Find-BrowserExe -Preferred $cfg.Browser
    if (-not $exe) {
        Write-Log '没找到 Edge 也没找到 Chrome，装一个！或者用 -Browser 指定完整路径' 'ERROR'
        exit $EXIT_ENV
    }
    Write-Log "浏览器: $exe"
    Write-Log '正在用独立配置目录启动浏览器…'
    if (-not (Start-DebugBrowser -Exe $exe -Port $cfg.DebugPort -ProfileDir $cfg.ProfileDir -StartUrl $cfg.StartUrl)) {
        Write-Log "浏览器已启动但调试端口 $($cfg.DebugPort) 连不上（可能被安全软件拦截）" 'ERROR'
        exit $EXIT_ENV
    }
    $version = Get-CdpVersion -Port $cfg.DebugPort
}
Write-Log "已连接: $($version.Browser)"

# ---------------- 布局第二步：浏览器已就绪，摆到左半屏 ----------------
# 浏览器必须等启动完才有窗口句柄，所以放在这里。
# 用带校验的版本：浏览器启动后会异步恢复上次的窗口状态（常见是最大化），
# 可能把刚摆好的位置覆盖掉，所以摆完要回读核对、不符就重设。
if ($cfg.ArrangeWindows) {
    try {
        $layoutBrowser = Get-BrowserWindowHandle
        $lay = Arrange-WindowsVerified -BrowserHandle $layoutBrowser -BrowserSide 'left'
        if (-not $lay.Ok) {
            Write-Log ('窗口没摆到位（试了 ' + $lay.Attempts + ' 轮，浏览器 ' + $lay.BrowserVisible + '），你可以手动拖一下') 'WARN'
        }
    } catch {
        Write-CdpDiag ('浏览器布局失败: ' + $_.Exception.Message)
    }
}

# ---- 2. 首次使用：只给指引 ----
if ($LaunchOnly) {
    Write-Log '浏览器已就绪。' 'OK'
    Write-Log '在这个浏览器窗口里干这两件事：' 'OK'
    Write-Log '  1) 登录学习通' 'OK'
    Write-Log '  2) 打开你要处理的课程的「学生学习页面」' 'OK'
    Write-Log '然后运行不带 -LaunchOnly 的命令开始自动连播。' 'OK'
    exit $EXIT_OK
}

# ---- 3. 找到课程页 ----
$page = Find-CoursePage -Port $cfg.DebugPort
if (-not $page) {
    # 没找到课程页时，先看是不是停在登录页 —— 是的话等用户登录，
    # 登录成功后自动打开课程列表，再重新找一次课程页。
    # 不要直接退出：那样用户每次都得先手动登录再重跑，很别扭。
    $tab = Get-AnyCourseTab -Port $cfg.DebugPort
    if ($tab.OnLoginPage -or -not $tab.Found) {
        if (Wait-UserLogin -Port $cfg.DebugPort) {
            $page = Find-CoursePage -Port $cfg.DebugPort
        }
    }
}

if (-not $page) {
    # 到这里说明登录了但没打开课程页
    $tab = Get-AnyCourseTab -Port $cfg.DebugPort
    if ($tab.Found) {
        Write-Host '  去点进你要刷的课，进「学生学习页面」' -ForegroundColor White
        Write-Host '  （左边目录、右边视频那个页面）' -ForegroundColor Gray
        Write-Host ''

        # 自动检测，一直等 —— 不催促、不提示。
        [void](Wait-Until -Message '' -TimeoutSeconds 14400 -Test {
            $null -ne (Find-CoursePage -Port $cfg.DebugPort)
        })
        Clear-ProgressLine
        $page = Find-CoursePage -Port $cfg.DebugPort
    }
}

if (-not $page) {
    Write-Log '还是没找到「学生学习页面」，走了。' 'ERROR'
    Write-Log '确认一下：打开的是具体课程页（左目录右视频），不是个人空间首页。' 'ERROR'
    exit $EXIT_ENV
}
Write-Log "课程页: $($page.url)"

$session = New-CdpSession -Page $page -Port $cfg.DebugPort
try {
    # 识别平台版本（legacy / mooc2），把选择器换成合并后的扁平表。
    # 必须放在登录判定之前：Test-LoggedIn 依赖 common 块里的 PageFingerprints。
    # 目录在 iframe 内的版本（mooc2）还需要 DirContextId，后续读取都要带上。
    $rawSelectors = $selectors
    $plat = Resolve-Platform -Session $session -RawSelectors $rawSelectors
    if ($plat.Version -eq '') {
        Write-Log '页面是课程页，但版本我不认识。学习通大概又改版了。' 'ERROR'
        Write-Log '确认一下：打开的是课程的「学生学习页面」。不行就刷新一下重跑。' 'ERROR'
        exit $EXIT_NO_DIRECTORY
    }
    $selectors = $plat.Selectors
    $dirCtx = $plat.DirContextId
    Write-Log ('平台版本: ' + $plat.Version + $(if ($dirCtx -gt 0) { '（目录在 iframe 内）' } else { '' }))

    if (-not (Test-LoggedIn -Session $session -Selectors $selectors)) {
        Write-Log '这页面不对！要么没登录，要么登录过期了。登完重跑。' 'ERROR'
        exit $EXIT_ENV
    }

    # ---- 4. 生成本次队列 ----
    $courseId = Get-CourseId -Session $session -Selectors $selectors -DirContextId $dirCtx
    $clazzId = Get-ClazzId -Session $session -Selectors $selectors -DirContextId $dirCtx
    Write-Log "课程 $courseId / 班级 $clazzId"

    # 先确认目录本身读得到。
    # 必须区分"目录为空"和"全部已完成"：前者是读失败（页面没加载好、
    # 登录页、或平台改版导致选择器失效），报成"全部已通过"会严重误导使用者。
    $allLessons = @(Get-LessonList -Session $session -Selectors $selectors -DirContextId $dirCtx)
    if ($allLessons.Count -eq 0) {
        Write-Log '目录读不到（0 个课节）。要么页面没加载完，要么不是课程页，要么学习通改版了。' 'ERROR'
        Write-Log '确认一下：打开的是课程的「学生学习页面」。不行就刷新一下重跑。' 'ERROR'
        Write-Log '要是页面明明正常还报这个错，那就是这门课根本没目录。' 'ERROR'
        exit $EXIT_NO_DIRECTORY
    }

    $queue = @(Build-LessonQueue -Session $session -Limit ([int]$cfg.MaxLessons))
    if ($queue.Count -eq 0) {
        $unfinished = @($allLessons | Where-Object { $_.Unfinished })
        if ($unfinished.Count -eq 0) {
            Write-Log ("课程目录共 " + $allLessons.Count + " 节，全部已通过。") 'OK'
            exit $EXIT_OK
        }
        Write-Log ("目录里有 " + $unfinished.Count + " 节未完成，但没能生成待处理队列（检查 -LessonIds 是否写错）") 'ERROR'
        exit $EXIT_NO_DIRECTORY
    }

    Write-Log ("本次待处理 " + $queue.Count + " 节: " + (@($queue | ForEach-Object { ' ' + $_.Id }) -join ''))

    if ($DryRun) {
        foreach ($lesson in $queue) { Write-Log ("  [待处理] " + $lesson.Id + "  " + $lesson.Title) }
        Write-Log 'DryRun：不播放，退出。' 'OK'
        exit $EXIT_OK
    }

    # ---- 5. 逐节播放 ----
    $windowHandle = Get-BrowserWindowHandle
    $doneCount = 0
    $failedIds = New-Object System.Collections.Generic.List[string]

    foreach ($lesson in $queue) {
        $ok = $false
        try {
            $ok = Invoke-Lesson -Session $session -Lesson $lesson -Selectors $selectors -Settings $cfg -WindowHandle $windowHandle -LogPath $cfg.LogFile
        } catch {
            Write-Log "处理课节 $($lesson.Id) 时出现异常: $($_.Exception.Message)" 'ERROR'
            Write-CdpDiag "Invoke-Lesson 异常: $($_.Exception.ToString())"
        }

        if ($ok) {
            $doneCount++
            Write-Log ("------ 课节 " + $lesson.Id + " 完成（" + $doneCount + "/" + $queue.Count + "）------") 'OK'
        } else {
            $failedIds.Add($lesson.Id) | Out-Null
            Write-Log ("------ 课节 " + $lesson.Id + " 未完成，跳过 ------") 'WARN'
        }
    }

    # ---- 6. 汇总 ----
    $remaining = @(Get-LessonList -Session $session -Selectors $selectors -DirContextId $dirCtx | Where-Object { $_.Unfinished })
    Write-Log ("=== 结束：完成 " + $doneCount + " 节，未完成 " + $failedIds.Count + " 节，目录中剩余未完成 " + $remaining.Count + " 节 ===")
    foreach ($l in $remaining) { Write-Log ("  仍未完成: " + $l.Id + "  " + $l.Title) 'WARN' }
    if ($failedIds.Count -gt 0) { Write-Log ("  本次未成功: " + (@($failedIds) -join ', ')) 'WARN' }
} finally {
    Close-CdpSession -Session $session
}

if ($StopBrowserWhenDone) {
    Write-Log '关闭本工具启动的浏览器…'
    Stop-DebugBrowser -ProfileDir $cfg.ProfileDir
}

exit $EXIT_OK
