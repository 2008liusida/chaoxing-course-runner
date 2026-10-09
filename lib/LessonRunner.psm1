<#
    教案：课节处理状态机。

    从 Run.ps1 抽出来的原因：
      由 Run.ps1 调用。
      两份实现必然失同步，所以放一条。

    依赖注入：-Selectors（选择器表）由调用方传入，
    本模块不自己去找 Selectors.psd1。
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CdpClient.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Chaoxing.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Video.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'PageVisibility.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Logging.psm1') -Force -DisableNameChecking

function Invoke-Lesson {
    <#
    .SYNOPSIS
        处理单节课：切课 -> 播放 -> 等平台登记完成 -> 返回结果。
    .PARAMETER Session
        CDP 会话（课程页顶层）。
    .PARAMETER Lesson
        课节对象，需含 Id 与 Title。
    .PARAMETER Selectors
        选择器表。
    .PARAMETER Settings
        设置对象（取 PlaybackRate / PollSeconds / MaxReplayPerLesson /
        MaxWaitMinutesPerLesson / KeepForeground / SwitchMode）。
    .PARAMETER WindowHandle
        浏览器窗口句柄，用于保持前台。
    .PARAMETER LogPath
        日志文件路径。本模块只往文件里记关键事件与分钟级里程碑；
        实时进度由 Write-ProgressLine 就地刷新，不进日志。
    .OUTPUTS
        Boolean：$true = 已确认完成。
    .NOTES
        所有失败路径都是"记日志 + 返回 $false"，不抛异常 ——
        一节课出问题不应该中断整批任务。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)]$Lesson,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [Parameter(Mandatory)]$Settings,
        [IntPtr]$WindowHandle = [IntPtr]::Zero,
        [Parameter(Mandatory)][string]$LogPath
    )

    # 单节课内的日志出口。
    # 设计：所有输出都同时上屏并落盘 —— 本模块只记关键事件，
    # 高频进度已由 Write-ProgressLine 就地刷新，不会淹没日志。
    function Say {
        param([string]$m, [string]$lv = 'INFO')
        Write-RunnerLog -Message $m -Path $LogPath -Level $lv
    }

    Say ('------ 课节 ' + $Lesson.Id + ' 开始 ------')

    # ---------------- 切课 ----------------
    # 切课阶段设一个总时长上限。
    # 为什么必须设：断网时 location.href 仍读得到（本地状态，不需要网络），
    # 于是切课会"发出导航但永远加载不出新页"，Wait-LessonCurrent 无限等待。
    # 上限让它在几分钟内失败并交回上层，而不是长时间无响应。
    $switchDeadline = (Get-Date).AddMinutes(4)
    $forceClick = ($Settings.SwitchMode -eq 'click')
    $how = Switch-Lesson -Session $Session -Selectors $Selectors -LessonId $Lesson.Id -ForceClick:$forceClick
    $switched = Wait-LessonCurrent -Session $Session -Selectors $Selectors -LessonId $Lesson.Id -TimeoutSeconds 75

    if (-not $switched) {
        # 优先判断"登录态过期/被踢到登录页"——这种情况重试没有意义，直接上报
        if (Test-OnLoginPage -Session $Session) {
            Say '页面已跳到学习通登录页，登录可能已过期。本节中止，请重新登录后再运行' 'ERROR'
            return $false
        }
        if ((Get-Date) -lt $switchDeadline) {
            Say ("首次切课未生效（方式 $how），重试一次") 'WARN'
            Start-Sleep -Seconds 5
            [void](Switch-Lesson -Session $Session -Selectors $Selectors -LessonId $Lesson.Id -ForceClick:$forceClick)
            $switched = Wait-LessonCurrent -Session $Session -Selectors $Selectors -LessonId $Lesson.Id -TimeoutSeconds 75
        }
    }
    if (-not $switched) {
        if (Test-OnLoginPage -Session $Session) {
            Say '页面停在登录页，登录已过期。请重新登录后再运行' 'ERROR'
            return $false
        }
        Say ("无法切换到课节 " + $Lesson.Id + "（方式 " + $how + "），跳过") 'ERROR'
        return $false
    }

    # ---------------- 本节循环 ----------------
    $replayLeft = [int]$Settings.MaxReplayPerLesson
    $deadline = (Get-Date).AddMinutes([double]$Settings.MaxWaitMinutesPerLesson)
    $noVideoPolls = 0
    # 连续多少轮发现"页面停在别的课节"。
    # 切换课节时 #curChapterId 会短暂保留旧值，所以要容许几轮，
    # 不能一读到不一致就判本节失败。必须在循环外初始化：
    # 本模块开了 Set-StrictMode -Version Latest，未初始化的变量自增会抛错。
    $awayPolls = 0
    $playbackStarted = $false
    $lastPosition = -1.0
    $stallCount = 0
    $lastMilestoneMin = -1
    # 一节课可能有多个视频任务点（实测 1.4 节有两个），每个视频在自己的
    # iframe 里。原来只取第一个，于是播完第一个就以为整节完成，
    # 其余任务点没做、课节永远完不成。这里记住当前在播第几个。
    $videoTotal = 0
    # 本节里已经播过的**播放器帧 id**，避免在同一节里来回打转。
    # 记帧 id 而不是上下文 id：后者每次调 Page.createIsolatedWorld 都会变，
    # 拿它去重永远匹配不上（实测过）。
    # 必须在循环外初始化 —— 本模块开了 Set-StrictMode，未初始化就引用会抛错。
    $playedFrameIds = @()
    # 本节当前正在播的帧 id，播到结尾时用来记账
    $currentFrameId = ''
    # 上次播报过的"还剩几个任务点"，避免每轮都刷同一句
    $jobAnnounced = -1

    while ((Get-Date) -lt $deadline) {
        # ---- 本节到底做完没有：以目录里的权威计数为准 ----
        # 目录里的 jobUnfinishCount 是平台自己维护的计数，它归零才算整节做完。
        # 必须放在最前面：后面选视频时要引用 $dirLeft 说明"剩下的是不是非视频任务点"。
        #
        # 为什么不能只看内容层帧：切课后帧是异步重新加载的，
        # 里面可能还是**上一节**的任务点列表。踩过的坑 ——
        # 2.1 节目录里明明写着"还剩 3 个任务点"，内容层帧里那个图标也写着
        # "任务点未完成"，工具却报"本节 1 个任务点平台均已标记完成"就跳过了。
        #
        # 走过的其它弯路（都别再犯）：
        #   1) 只看 .ans-job-finished 这个 class —— 某些版本里它课节刚点开就存在，
        #      把没播的课节谎报成完成。
        #   2) class 标记 + 视频播放位置交叉验证 —— 更糟：已完成的课节重新
        #      打开时视频位置会归零，于是把平台明确标注已完成的课节判成
        #      "标记不可信"，反复重播，还打出误导使用者的警告。
        $latest = Get-LessonById -Session $Session -Selectors $Selectors -LessonId $Lesson.Id
        $dirLeft = -1
        if ($latest -and $latest.PSObject.Properties['UnfinishedCount']) {
            $dirLeft = [int]$latest.UnfinishedCount
        }

        if ($dirLeft -eq 0) {
            Clear-ProgressLine
            Say '本节任务点已全部完成（目录计数已归零）' 'OK'
            return $true
        }
        if ($dirLeft -gt 0 -and -not $playbackStarted -and $jobAnnounced -ne $dirLeft) {
            $jobAnnounced = $dirLeft
            Say ('本节还剩 ' + $dirLeft + ' 个任务点未完成') 'INFO'
        }

        # 在**还没做完**的视频任务点里挑一个。
        # 不能只按下标取：视频帧的顺序与数量会变（第二个视频的 iframe
        # 往往要等第一个播完才加载），按下标会退回已完成的那个，
        # 于是反复重播第一个视频、永远轮不到第二个。这是使用者实测到的现象。
        $pick = Select-NextVideoContext -Session $Session -Selectors $Selectors -ExcludeFrameIds $playedFrameIds
        if ($pick.Total -gt 0) { $videoTotal = $pick.Total }
        $videoCtx = [int]$pick.ContextId
        $currentFrameId = [string]$pick.FrameId

        if ($videoCtx -gt 0 -and $videoTotal -gt 1 -and -not $playbackStarted) {
            Say ('本节共 ' + $videoTotal + ' 个视频任务点' +
                 $(if ($pick.Pending -gt 0) { '，还有 ' + $pick.Pending + ' 个没播完' } else { '' })) 'INFO'
        }
        if ($videoCtx -eq 0 -and $pick.Total -gt 0) {
            if ($dirLeft -le 0) { return $true }

            # 视频都播完了，但目录还没归零。
            # **别立刻下结论** —— 平台是异步登记的：实测 2.2/2.3/2.4 三节，
            # 工具跑的时候计数还没更新、当场报"没活干"，
            # 过几分钟再查却都变成"完成"了。那几节其实刷上了。
            # 所以先给平台一点时间，反复查目录计数。
            if (-not $playbackStarted) { }
            $settleDeadline = (Get-Date).AddSeconds([double]$Settings.JobSettleSeconds)
            $settled = -1
            while ((Get-Date) -lt $settleDeadline) {
                Start-Sleep -Seconds 5
                $cur = Get-LessonById -Session $Session -Selectors $Selectors -LessonId $Lesson.Id
                if ($cur -and $cur.PSObject.Properties['UnfinishedCount']) {
                    $settled = [int]$cur.UnfinishedCount
                }
                if ($settled -eq 0) { break }
                $remain = [int]($settleDeadline - (Get-Date)).TotalSeconds
                if ($remain -gt 0 -and ($remain % 15) -lt 6) {
                    Say ('视频已播完，等平台登记（还剩 ' + $remain + ' 秒，目录未完成 ' + $settled + '）') 'DEBUG'
                }
            }

            if ($settled -eq 0) {
                Clear-ProgressLine
                Say '本节任务点已全部完成（目录计数已归零）' 'OK'
                return $true
            }

            # 等过之后还没归零 —— 剩下的确实不是视频（例如 PPT）。
            # 这不是失败，是工具做不了的部分，所以要说清楚、不要空转。
            Say ('本节能播的视频都播完了，但目录还差 ' + $(if ($settled -gt 0) { $settled } else { $dirLeft }) +
                 ' 个任务点未完成 —— 剩下的多半是 PPT 之类的非视频任务点。') 'WARN'
            Say '把 PPT 翻到底（翻完会弹一个确认框，点掉才算完成）后，再跑一次本工具。' 'WARN'
            Write-CdpDiag ('课节 ' + $Lesson.Id + ' 视频已做完并等待 ' + $Settings.JobSettleSeconds +
                ' 秒，目录仍剩 ' + $settled + '，判定为非视频任务点')
            return $false
        }

        # 保证页面可见：Chromium 在页面 hidden 时不允许加载/播放视频。
        # 传入 VideoContextId 后，函数会先只读可见性 —— 正常情况直接返回，
        # 不抢前台也不等待；只有确实 hidden 时才恢复窗口与激活标签。
        if ($Settings.KeepForeground) {
            $visArgs = @{
                Session        = $Session
                WindowHandle   = $WindowHandle
                VideoContextId = $videoCtx
            }
            # 用 PSObject 判断：配置文件里没写这一项时不应抛异常
            if ($Settings.PSObject.Properties['ArrangeWindows'] -and $Settings.ArrangeWindows) {
                $visArgs.LeftHalf = $true
            }
            $vis = Enable-LessonVideoPlayback @visArgs
            if (-not $vis.Ok) {
                Say ("页面当前不可见（" + $vis.TopVisible + "），视频可能无法加载；已尝试恢复窗口与激活标签") 'WARN'
            }
        }

        # ---- 没有视频帧：可能是非视频课节，也可能页面没加载好 ----
        if ($videoCtx -le 0) {
            $noVideoPolls++
            Start-Sleep -Seconds 6

            # 先判断"当前课节"到底是谁。
            # 三种情况要分开处理，不能一律判失败：
            #   a) 页面停在别的课节 —— 可能只是切换还没完成，
            #      也可能使用者自己点了目录跳走；后者不该算失败，
            #      记下来下一轮重来时再补。
            #   b) 页面停在本节，但视频帧还读不到 —— 纯粹是时机问题，继续等。
            #   c) 本节其实已经完成 —— 直接算成功。
            $curId = [string](Get-CurrentLessonId -Session $Session -Selectors $Selectors)
            if ($curId -and $curId -ne $Lesson.Id) {
                # 给切换留出时间：连等 3 轮（约 18 秒）再下结论
                $awayPolls++
                if ($awayPolls -lt 3) {
                    Write-ProgressLine ("页面似乎在别的课节（" + $curId + "），等它切回来…")
                    continue
                }
                Write-CdpDiag ('课节 ' + $Lesson.Id + ' 中途页面停在 ' + $curId +
                    '，读不到视频帧，本节跳过，稍后重来')
                Say ("页面停在别的课节（" + $curId + "），本节先跳过，稍后重来: " + $Lesson.Id) 'WARN'
                return $false
            }
            $awayPolls = 0

            $latest = Get-LessonById -Session $Session -Selectors $Selectors -LessonId $Lesson.Id
            if ($latest -and -not $latest.Unfinished) {
                Say '该课节已标记完成' 'OK'
                return $true
            }

            # 读不到视频帧时**不要刷新页面**。
            # 踩过的坑：刷新会把已经播过的进度清零（未完成的视频不允许拖拽），
            # 于是越救越糟；而且刷新会让这一节后面所有 CDP 调用都变慢，
            # 连带把下一节的切课也拖垮。宁可多等，也不要重来。
            #
            # 改成：间隔性地重新触发一次切课（等价于"再点一次目录"），
            # 这比刷新温和，且不会清零进度。
            if (($noVideoPolls % 8) -eq 0) {
                Say ("连续读不到视频帧（第 " + $noVideoPolls + " 轮），重新触发一次切课") 'WARN'
                try {
                    Switch-Lesson -Session $Session -Selectors $Selectors -LessonId $Lesson.Id | Out-Null
                } catch {
                    Write-CdpDiag ('重新切课失败: ' + $_.Exception.Message)
                }
                Start-Sleep -Seconds 6
                continue
            }
            if ($noVideoPolls -ge 30) {
                # 约 3 分钟还读不到，才是真的没有视频（作业/讨论/测验类任务点）
                Say ("该课节没有可播放的视频（可能是作业/讨论/测验类任务点），跳过: " + $Lesson.Id) 'WARN'
                return $false
            }
            continue
        }
        $noVideoPolls = 0
        $awayPolls = 0

        # ---- 读播放器状态（先读，下面判断完成时要靠它交叉验证）----
        $state = Get-VideoState -Session $Session -ContextId $videoCtx
        if (-not $state.Ok) {
            Say ("读不到播放器状态（" + $state.Error + "），稍后重试") 'DEBUG'
            Start-Sleep -Seconds 6
            continue
        }

        # 目录计数已在循环开头算好（那里要先用到它来决定"还值不值得继续"），
        # 这里不再重复读取。

        # 内容层只用来决定"下一个该播哪个视频"，不用它判完成
        $cardsCtx = Get-CardsContext -Session $Session -Selectors $Selectors
        $jobStates = @()
        if ($cardsCtx -gt 0) {
            $jobStates = @(Get-JobStates -Session $Session -Selectors $Selectors -ContextId $cardsCtx)
        }
        if ($jobStates.Count -gt 0) {
            Write-CdpDiag ('课节 ' + $Lesson.Id + ' 目录剩余=' + $dirLeft +
                '，内容层任务点=' + $jobStates.Count +
                '，其中已完成=' + @($jobStates | Where-Object { $_.Finished }).Count)
        }

        # ---- 时长未就绪：先触发播放（学习通要靠 play() 才开始加载）----
        if ($state.Duration -le 0) {
            $r = Start-VideoPlayback -Session $Session -ContextId $videoCtx -Rate $Settings.PlaybackRate
            Say ("时长未就绪，尝试播放: " + $r)
            Start-Sleep -Seconds 8
            continue
        }

        # ---- 暂停中则继续播放 ----
        if ($state.Paused) {
            $r = Start-VideoPlayback -Session $Session -ContextId $videoCtx -Rate $Settings.PlaybackRate
            Say ("暂停中 -> 继续播放: " + $r)
            Start-Sleep -Seconds 3
            continue
        }

        if (-not $playbackStarted) {
            $playbackStarted = $true
            Say ("开始播放：时长 " + [math]::Round($state.Duration, 1) + " 秒，从 " + [math]::Round($state.Current, 1) + " 秒处继续")
        }

        # ---- 停滞检测 ----
        # 阈值按"秒"换算而不是按"轮询次数"，否则改 PollSeconds 会连带改变容忍时长：
        # 20 秒轮询下 12 次是 4 分钟，1 秒轮询下同样 12 次只剩 12 秒，
        # 正常运行中的缓冲卡顿会被误判成失败。
        if ($state.Current -gt $lastPosition + 0.3) { $stallCount = 0 } else { $stallCount++ }
        $lastPosition = $state.Current

        $stallRetryPolls = [int][math]::Ceiling(60.0 / [math]::Max(1, [int]$Settings.PollSeconds))
        $stallGiveUpPolls = [int][math]::Ceiling(240.0 / [math]::Max(1, [int]$Settings.PollSeconds))

        if ($stallCount -gt 0 -and ($stallCount % $stallRetryPolls) -eq 0) {
            Say ("进度停滞约 " + [int]($stallCount * $Settings.PollSeconds) + " 秒，尝试继续播放") 'WARN'
            $r = Start-VideoPlayback -Session $Session -ContextId $videoCtx -Rate $Settings.PlaybackRate
            Say ("  继续播放: " + $r)
        }
        if ($stallCount -ge $stallGiveUpPolls) {
            Say ("长时间无进展（约 " + [int]($stallCount * $Settings.PollSeconds) + " 秒），放弃本节") 'ERROR'
            return $false
        }

        # 播放进度用单条进度条就地刷新，不逐行刷屏，也不写日志文件。
        # 文件里只按分钟留里程碑（见下方 $lastMilestoneMin），
        # 避免一晚上把日志撑到几十万行、淹没真正重要的事件。
        $pct = 0
        if ($state.Duration -gt 0) { $pct = [int](($state.Current / $state.Duration) * 100) }
        if ($pct -gt 100) { $pct = 100 }
        if ($pct -lt 0) { $pct = 0 }

        $barWidth = 28
        $filled = [int]([math]::Round($barWidth * $pct / 100.0))
        if ($filled -gt $barWidth) { $filled = $barWidth }
        if ($filled -lt 0) { $filled = 0 }
        $bar = ('█' * $filled) + ('░' * ($barWidth - $filled))

        $curMin = [int]($state.Current / 60)
        $durMin = [int]($state.Duration / 60)
        $curSec = [int]($state.Current % 60)
        $durSec = [int]($state.Duration % 60)

        $progressText = ("  $bar {0,3}%   " -f $pct) +
            ("{0,2}:{1:00} / {2,2}:{3:00}" -f $curMin, $curSec, $durMin, $durSec)
        Write-ProgressLine -Text $progressText

        # 每分钟往日志文件里留一条里程碑，便于事后核查
        $milestone = [int]($state.Current / 60)
        if ($milestone -gt $lastMilestoneMin) {
            $lastMilestoneMin = $milestone
            # 里程碑只落盘、不上屏 —— 上屏会打断进度条的就地刷新。
            $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            $line = '[' + $stamp + '] [DEBUG] 播放里程碑 ' + $milestone + ' 分钟 / 共 ' + $durMin + ' 分钟（' + $pct + '%）'
            try {
                $logDir = Split-Path -Parent $LogPath
                if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
                Add-Content -Path $LogPath -Value $line -Encoding UTF8
            } catch { }
        }

        # ---- 播到结尾 ----
        if ($state.Current -ge ($state.Duration - 1)) {
            # 记下这个帧已播过，避免它被再次选中
            if ($currentFrameId -and ($playedFrameIds -notcontains [string]$currentFrameId)) {
                $playedFrameIds = @($playedFrameIds + [string]$currentFrameId)
            }
            # 这一段播完了。还轮不到在这里决定"下一个播哪个" ——
            # 循环开头的 Select-NextVideoContext 会按"未完成 + 没播过"
            # 重新挑；下面紧接着的那段会在确认本视频已登记后 continue，
            # 回到开头自然就换片了。
            # （原来这里按下标再找一遍，既重复又容易退回已完成的视频。）
            Say '已播到结尾，等待平台登记完成状态…'

            # 已播到结尾，所以此时 DOM 标记是可信的 —— 位置本身已经证明播完了。
            # 这里同时看"任务点图标"和"课节计数"，任一显示已完成即认。
            $registered = $false
            for ($i = 0; $i -lt 8; $i++) {
                Start-Sleep -Seconds 5
                $c = Get-CardsContext -Session $Session -Selectors $Selectors
                if ($c -gt 0) {
                    if (Test-JobFinished -Session $Session -Selectors $Selectors -ContextId $c) { $registered = $true; break }
                    # 图标 class 不再含 clear 也说明平台认了
                    $ic = Get-JobIconClass -Session $Session -Selectors $Selectors -ContextId $c
                    $clearMark = [string]$Selectors.JobIconClear
                    if ($ic -and $clearMark -and ($ic -notmatch [regex]::Escape($clearMark))) {
                        $registered = $true; break
                    }
                }
                $l = Get-LessonById -Session $Session -Selectors $Selectors -LessonId $Lesson.Id
                if ($l -and -not $l.Unfinished) { $registered = $true; break }
            }

            if ($registered) {
                Say '任务点已登记完成' 'OK'
                return $true
            }

            # 先看这个视频自己的任务点是不是已经被平台标记完成了。
            # 是的话说明视频这段没问题，本节没归零是因为还有别的任务点
            # （PPT 之类），这时重播视频纯属白费时间 —— 使用者实测到
            # 工具把已完成的第一个视频反复重播，就是这么来的。
            $cardsNow = Get-CardsContext -Session $Session -Selectors $Selectors
            $thisDone = $false
            if ($cardsNow -gt 0) {
                $st = @(Get-JobStates -Session $Session -Selectors $Selectors -ContextId $cardsNow) |
                      Where-Object { $_.HasVideo -and $_.Finished }
                if (@($st).Count -gt 0) { $thisDone = $true }
            }
            if ($thisDone -or ($playedFrameIds -contains [string]$currentFrameId)) {
                if ($currentFrameId) {
                    $playedFrameIds = @($playedFrameIds + [string]$currentFrameId | Select-Object -Unique)
                }
                $nxt = Select-NextVideoContext -Session $Session -Selectors $Selectors -ExcludeFrameIds $playedFrameIds
                if ($nxt.ContextId -gt 0) {
                    Say '这个视频已登记完成，接着播下一个视频任务点'
                    $videoCtx = [int]$nxt.ContextId
                    $playbackStarted = $false
                    $lastPosition = -1.0
                    $stallCount = 0
                    $lastMilestoneMin = -1
                    Start-Sleep -Seconds 3
                    continue
                }
                Say ('本节的视频任务点都已完成，目录还差 ' + $dirLeft +
                     ' 个（多半是 PPT 之类的非视频任务点，需要手动完成）') 'WARN'
                return $false
            }

            if ($replayLeft -gt 0) {
                $replayLeft--
                Say ("播完但未被登记（可能要求 100% 时长），从头重播；剩余重播次数 " + $replayLeft) 'WARN'
                $r = Restart-Video -Session $Session -ContextId $videoCtx -Rate $Settings.PlaybackRate
                Say ("  重播: " + $r)
                $lastPosition = -1.0
                $stallCount = 0
                Start-Sleep -Seconds 8
                continue
            }

            Say '播完且重播次数用尽仍未登记，跳过本节（建议手动确认）' 'ERROR'
            return $false
        }

        Start-Sleep -Seconds ([int]$Settings.PollSeconds)
    }

    Say ("本节超过最长等待时间 " + $Settings.MaxWaitMinutesPerLesson + " 分钟，跳过") 'ERROR'
    return $false
}

Export-ModuleMember -Function Invoke-Lesson
