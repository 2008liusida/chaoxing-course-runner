<#
    CDP 传输层（Chrome DevTools Protocol over WebSocket）

    这一层与"超星"完全无关，可以单独复用到任何浏览器自动化场景。
    只依赖 .NET 自带的 System.Net.WebSockets，没有第三方依赖。

    通信模型：一条 WebSocket 连接 = 一个 target（本工具里是"一个标签页"）。
    每发一条命令带自增 id，接收时需要丢弃途中的事件消息，
    直到读到匹配该 id 的响应。Send-Cdp 就负责这件事。

    公开函数：
      Get-CdpVersion / Get-CdpTargets / Select-CdpPage  —— 走 HTTP /json 接口
      New-CdpSession / Close-CdpSession                 —— 建/关会话
      Send-Cdp                                          —— 发任意 CDP 命令
      Invoke-CdpJs                                      —— 在指定上下文求值 JS
      Get-CdpFrames / Get-FrameContext                  —— 帧与执行上下文
      Set-CdpLogPath / Write-CdpDiag                    —— 排障日志
#>

Set-StrictMode -Version Latest

# 排障日志路径。
# 注意：不要用模块级变量 $script:CdpLogPath。
# PowerShell 里每个 .psm1 的模块作用域是独立的：Chaoxing / Video 各自
# Import-Module 了一份 CdpClient 副本，于是 "设一次、处处生效" 不成立，
# 诊断日志会静默丢失（表现为"明明有失败，日志却是空的"）。
# 这里改用进程级环境变量，保证无论从哪个模块实例调用都写同一个文件。
function Set-CdpLogPath {
    <#
    .SYNOPSIS
        指定 CDP 层的诊断日志文件。定位"读不到帧 / 求值失败"时非常有用。
    #>
    [CmdletBinding()]
    param([string]$Path)
    if ($Path) { $env:CCR_CDP_LOG = $Path }
    else { Remove-Item Env:\CCR_CDP_LOG -ErrorAction SilentlyContinue }
}

function Write-CdpDiag {
    <#
    .SYNOPSIS
        写一条 CDP 诊断信息（仅在设置了日志路径时生效）。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message)
    $logPath = $env:CCR_CDP_LOG
    if (-not $logPath) { return }
    try {
        $dir = Split-Path -Parent $logPath
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $logPath -Encoding UTF8 -Value (
            '[{0}] [DEBUG] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Message
        )
    } catch { }
}

# ---------------------------------------------------------------- HTTP 接口



function Invoke-CdpNavigate {
    <#
    .SYNOPSIS
        让某个标签页主动导航到指定地址。
    .DESCRIPTION
        为什么需要它：Edge 启动时虽然把 URL 写在命令行里，但冷启动时
        常常没有照做 —— 窗口开着、地址栏空白、页面 url 为空。
        这时不能等，要自己发一条 Page.navigate。

        这是"浏览器起来了但页面白屏"最可靠的对策：
        不依赖浏览器怎么解析命令行参数。
    .PARAMETER Page
        Get-CdpTargets 返回的标签页。
    .PARAMETER Port
        调试端口。
    .PARAMETER Url
        目标地址。
    .OUTPUTS
        Boolean：成功发出导航返回 $true。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Page,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Url
    )

    if (-not $Page.webSocketDebuggerUrl) { return $false }

    try {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        $ws.ConnectAsync([Uri]$Page.webSocketDebuggerUrl,
            [System.Threading.CancellationToken]::None).Wait(10000) | Out-Null
        if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
            Write-CdpDiag 'Invoke-CdpNavigate: WebSocket 没连上'
            return $false
        }

        # 用 CDP 的 JSON 转义规则处理 URL 里的特殊字符
        $safe = ConvertTo-JsLiteral -Value $Url
        $msg = '{"id":1,"method":"Page.navigate","params":{"url":"' + $safe + '"}}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $ws.SendAsync(
            (New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)),
            [System.Net.WebSockets.WebSocketMessageType]::Text, $true,
            [System.Threading.CancellationToken]::None).Wait(8000) | Out-Null

        # 不等响应体：导航一旦发出就够，后续用 Test-PageLoaded 判断结果
        Start-Sleep -Milliseconds 300
        $ws.Dispose()
        return $true
    } catch {
        Write-CdpDiag ('Invoke-CdpNavigate 失败: ' + $_.Exception.Message)
        return $false
    }
}

function Test-PageLoaded {
    <#
    .SYNOPSIS
        判断某个标签页是否真的加载出了内容。
    .DESCRIPTION
        为什么需要它：浏览器起来了、调试端口通了，不代表页面加载成功。
        断网时 Chromium 会显示一片空白，既没有标题也不报错 ——
        使用者只看到一个白窗口，不知道是工具坏了还是网络问题。

        判定依据：
          · url 为空            -> 页面从未导航（启动时就没拿到地址）
          · title 与正文都为空  -> 白屏（多半是网络不通）
    .PARAMETER Page
        Get-CdpTargets 返回的标签页对象。
    .PARAMETER Port
        调试端口。
    .PARAMETER Session
        已有的 CDP 会话。给了就用它，省一次连接。
    .PARAMETER WaitSeconds
        等待页面出现内容的最长秒数，默认 15。
        必须等待：冷启动时调试端口先就绪，此时页面还没开始导航，
        立刻检查会误报"没有地址"—— 实测就是这样。
    .OUTPUTS
        PSCustomObject：@{ Loaded; Url; Title; BodyLen; Reason; Waited }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Page,
        [int]$Port = 9222,
        $Session = $null,
        [int]$WaitSeconds = 15
    )

    # 端口就绪不等于页面就绪，这里等一等。
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $rawUrl = ''
    $waited = 0
    while ($true) {
        $rawUrl = ''
        if ($Page.PSObject.Properties['url'] -and $Page.url) { $rawUrl = [string]$Page.url }
        if ($rawUrl -and $rawUrl -ne 'about:blank') { break }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 500
        $waited += 0.5
        # 目标对象是快照，URL 会随后续导航变化，需要重新取
        try {
            $again = @(Get-CdpTargets -Port $Port) |
                Where-Object { $_.type -eq 'page' } | Select-Object -First 1
            if ($again) { $Page = $again }
        } catch { }
    }

    if (-not $rawUrl -or $rawUrl -eq 'about:blank') {
        return [pscustomobject]@{
            Loaded = $false; Url = $rawUrl; Title = ''; BodyLen = 0; Waited = $waited
            Reason = ('等了 ' + [int]$waited + ' 秒，页面始终没有地址' +
                      '（导航没发生，或渲染进程崩了 —— 浏览器窗口会是白屏）')
        }
    }

    # 到这里已经有 URL 了 —— 说明浏览器确实导航过去了。
    # 下面只是尽量再确认正文渲染出来；连不上会话不算失败。
    $s = $Session
    $own = $false
    if (-not $s) {
        try {
            $s = New-CdpSession -Page $Page -Port $Port
            $own = $true
        } catch {
            # 连不上会话 —— 多半是渲染进程崩了。
            # 这里不能返回 Loaded=$true：会掩盖崩溃，
            # 上层就不重试了，使用者只看到白窗口。
            Write-CdpDiag ('建立会话失败: ' + $_.Exception.Message)
            return [pscustomobject]@{
                Loaded = $false; Url = $rawUrl; Title = ''
                BodyLen = -1; Waited = $waited
                Reason = ('连不上页面（渲染进程可能已崩溃）: ' + $_.Exception.Message)
            }
        }
    }

    $js = @'
(function(){
  var b = document.body;
  return JSON.stringify({
    t: document.title || '',
    n: b ? ((b.innerText || '').replace(/\s+/g,' ').trim().length) : 0
  });
})()
'@

    # 有地址了，再等正文渲染出来 —— 导航刚发起时正文还是空的。
    $loaded = $false
    $title = ''
    $bodyLen = 0
    $reason = ''
    try {
        while ($true) {
            $r = $null
            try { $r = Invoke-CdpJs -Session $s -Expression $js } catch { $r = $null }

            if ($r -and -not $r.Error) {
                try {
                    $o = $r.Value | ConvertFrom-Json
                    $title = [string]$o.t
                    $bodyLen = [int]$o.n
                    # 必须有标题才算成功。
                # 只靠"正文长度大于 0"不够：白屏时 body 里往往还有
                # 外壳元素，innerText 却可能是空的或几个字，
                # 实测就因此把白屏判成了加载成功。
                if ($title) { $loaded = $true; $reason = ''; break }
                } catch { }
            }

            if ((Get-Date) -ge $deadline) { break }

            Start-Sleep -Milliseconds 700
            $waited += 0.7
            # 会话可能因为页面还在加载而失效，重建一个再试
            if ($own) {
                try { $s.Dispose() } catch { }
                try { $s = New-CdpSession -Page $Page -Port $Port } catch { $s = $null }
                if (-not $s) { break }
            }
        }
    } finally {
        if ($own -and $s) { try { $s.Dispose() } catch { } }
    }

    # 判据要严：只有"地址有了、正文也确认到了"才算加载成功。
    # 之前放得太宽（有地址就算成功，甚至地址为空也算），
    # 结果空白页被当成成功 —— 日志打出"页面已加载: "后面是空的，
    # 上层的重试逻辑因此永远不触发。
    # 最后一道关：地址与标题必须都有。
    # 渲染进程崩溃时地址可能是空的、也可能残留上一次的值，
    # 两种都不能算加载成功。
    if ($loaded -and (-not $rawUrl -or -not $title)) {
        $loaded = $false
        $reason = ('判定依据不足（地址=[' + $rawUrl + '] 标题=[' + $title + ']）')
    }
    if (-not $loaded) {
        if (-not $reason) {
            if ($rawUrl) { $reason = '有地址，但读不到标题（页面可能还在加载）' }
            else { $reason = '页面没有地址也没有标题（导航没发生或渲染进程崩了）' }
        }
    }

    # 把判定依据也带上：排查"为什么被当成加载成功"时全靠它。
    # 之前的日志只打 Title，标题为空时看不出到底哪一项让判定通过的。
    Write-CdpDiag ('Test-PageLoaded: Loaded=' + $loaded +
        ' Url=[' + $rawUrl + '] Title=[' + $title + '] BodyLen=' + $bodyLen +
        ' 等待=' + [math]::Round($waited, 1) + 's')

    return [pscustomobject]@{
        Loaded = $loaded; Url = $rawUrl; Title = $title; BodyLen = $bodyLen
        Reason = $reason; Waited = $waited
    }
}

function Get-CdpVersion {
    <#
    .SYNOPSIS
        查询调试端口是否可用。不可用返回 $null（不抛异常，便于当"探活"用）。
    .EXAMPLE
        if (Get-CdpVersion -Port 9222) { '浏览器已在调试模式' }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port)
    try {
        return Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/version" -f $Port) -TimeoutSec 4
    } catch {
        return $null
    }
}

function Get-CdpTargets {
    <#
    .SYNOPSIS
        列出当前所有调试目标（标签页、service worker 等）。失败返回空数组。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Port)
    # 注意别写成 return @(Invoke-RestMethod ...)：
    # Invoke-RestMethod 返回的已经是数组，再套 @() 会变成"数组里装数组"，
    # 于是每一项都成了只有一个元素的数组 ——
    # $_.type 靠成员枚举还能读到，但 $_.PSObject.Properties['url'] 会是空，
    # 症状是"页面明明有 URL，工具却读到空"。
    # 正确写法：先赋值给变量，再原样输出。
    #   错法一：return @(Invoke-RestMethod ...)  -> 数组里装数组（实测确认）
    #   错法二：return Write-Output -NoEnumerate (...) -> 同样多一层
    # 两种错法的症状一样：$_.type 靠成员枚举还能读到，但
    # $_.PSObject.Properties['url'] 是空 —— 于是"页面明明有 URL，工具读到空"。
    try {
        $targets = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/json/list" -f $Port) -TimeoutSec 6
        if ($null -eq $targets) { return @() }
        # 单个元素时 ConvertFrom-Json 可能给出非数组，统一成数组
        if ($targets -isnot [System.Array]) { $targets = @($targets) }
        return $targets
    } catch {
        return @()
    }
}

function Select-CdpPage {
    <#
    .SYNOPSIS
        在所有 page 类型目标里挑一个：优先 URL 匹配 $UrlMatch，否则第一个。
    .NOTES
        只做 URL 匹配，不理解页面内容。需要"按页面内容识别"请用上层的
        Find-CoursePage（Run.ps1 中实现）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port,
        [string]$UrlMatch = ''
    )
    $pages = @(Get-CdpTargets -Port $Port | Where-Object { $_.type -eq 'page' })
    if ($pages.Count -eq 0) { return $null }
    if ($UrlMatch) {
        foreach ($p in $pages) { if ($p.url -match $UrlMatch) { return $p } }
    }
    return $pages[0]
}

# ---------------------------------------------------------------- 会话

function New-CdpSession {
    <#
    .SYNOPSIS
        与一个标签页建立 CDP 会话（flatten 模式），并启用 Page / Runtime 域。
    .PARAMETER Page
        Get-CdpTargets 返回的目标对象（需要含 id 与 webSocketDebuggerUrl）。
    .PARAMETER Port
        调试端口，仅用于诊断记录。
    .OUTPUTS
        PSCustomObject：Ws / Port / TargetId / SessionId / CdpId
    .EXAMPLE
        $page = Select-CdpPage -Port 9222
        $s = New-CdpSession -Page $page -Port 9222
        Invoke-CdpJs -Session $s -Expression 'location.href'
        Close-CdpSession -Session $s
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Page,
        [Parameter(Mandatory)][int]$Port
    )

    # 不发 Origin 头：部分浏览器版本会以 403 拒绝带 Origin 的 WebSocket 连接。
    # .NET Framework 上 SetRequestHeader 可能不受支持，因此忽略异常，
    # 实际生效依赖浏览器启动参数 --remote-allow-origins=*。
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    try { $ws.Options.SetRequestHeader('Origin', '') } catch { }

    $task = $ws.ConnectAsync([Uri]$Page.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None)
    # 25 秒：页面在播视频时渲染进程很忙，建会话会明显变慢。
    # 原来 10 秒会在这里抛超时，上层看到的是"读不到播放器状态"。
    if (-not $task.Wait(25000)) { throw "WebSocket 连接超时: $($Page.webSocketDebuggerUrl)" }
    if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { throw "WebSocket 未打开: $($ws.State)" }

    $session = [pscustomobject]@{
        Ws        = $ws
        Port      = $Port
        TargetId  = $Page.id
        SessionId = $null
        CdpId     = 0
    }

    $attached = Send-Cdp -Session $session -Method 'Target.attachToTarget' -Params @{ targetId = $Page.id; flatten = $true }
    $session.SessionId = Get-CdpField -Object $attached -Path 'result.sessionId'
    if (-not $session.SessionId) { throw 'Target.attachToTarget 未返回 sessionId' }

    Send-Cdp -Session $session -Method 'Page.enable' -Params @{} | Out-Null
    Send-Cdp -Session $session -Method 'Runtime.enable' -Params @{} | Out-Null
    return $session
}

function Close-CdpSession {
    <#
    .SYNOPSIS
        关闭会话。可安全地对 $null 调用。
    #>
    [CmdletBinding()]
    param($Session)
    if ($null -eq $Session) { return }
    try { $Session.Ws.Dispose() } catch { }
}

function Get-CdpField {
    <#
    .SYNOPSIS
        安全地按路径读取 CDP 响应里的字段（内部辅助）。
    .NOTES
        不用 $obj.a.b.c 是因为 StrictMode 下属性不存在会抛异常，
        而 CDP 的响应结构随命令而异，缺字段是常态。
    #>
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Path)
    $cur = $Object
    foreach ($seg in ($Path -split '\.')) {
        if ($null -eq $cur) { return $null }
        $names = @($cur.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names -notcontains $seg) { return $null }
        $cur = $cur.$seg
    }
    return $cur
}

function Send-Cdp {
    <#
    .SYNOPSIS
        发送一条 CDP 命令并等待其响应，途中事件消息全部丢弃。
    .PARAMETER Session
        New-CdpSession 返回的会话对象。
    .PARAMETER Method
        CDP 方法名，如 'Page.navigate'。
    .PARAMETER Params
        参数字哈希表。
    .PARAMETER FireAndForget
        只发送、不等响应。用于 Page.navigate 这类会销毁页面上下文的命令。
    .PARAMETER TimeoutSeconds
        整个调用（发送 + 接收）的总时长上限，默认 30 秒。
        注意这是"总预算"而不是"每条消息"的上限 —— 见下方 NOTES。
    .OUTPUTS
        解析后的响应对象（可能含 error 字段，由调用方判断）。
    .NOTES
        若响应带 error，会同时写入诊断日志，便于事后排查。

        为什么需要总预算：若只限制"每条消息"的等待时间，
        累计等待时间可能被反复耗尽，导致单个调用长时间不返回。
        调用方若需要更长等待（如等待页面加载），应显式传入更大的值，
        而不是依赖无上限的重试。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSeconds = 30,
        [switch]$FireAndForget
    )

    $Session.CdpId++
    $want = $Session.CdpId

    $payload = @{ id = $want; method = $Method; params = $Params }
    if ($Session.SessionId) { $payload.sessionId = $Session.SessionId }

    $json = $payload | ConvertTo-Json -Compress -Depth 10
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $send = $Session.Ws.SendAsync(
        (New-Object System.ArraySegment[byte] -ArgumentList @(, $bytes)),
        [System.Net.WebSockets.WebSocketMessageType]::Text,
        $true,
        [System.Threading.CancellationToken]::None
    )
    # 同上：播放期间渲染进程忙，发送响应会慢。
    if (-not $send.Wait(20000)) { throw "CDP 发送超时: $Method" }

    # FireAndForget：命令已发出，不等响应直接返回。
    #
    # 为什么需要它：Page.navigate 会触发整页导航，页面上下文随之销毁，
    # 响应可能永远不来。若在这里等待并超时抛错，那条迟到的响应会留在
    # WebSocket 缓冲区里没被读走，之后每个调用都会先读到它、ID 对不上，
    # 于是整条会话错乱，后续所有切课都会失败。
    # 这类"发了就不管"的命令应交给页面状态轮询去确认结果。
    if ($FireAndForget) { return $null }

    # ---- 接收 ----
    # 这里必须有一个"总时长"上限，而不只是"每条消息的上限"。
    # 若只限制"每条消息"的等待时间，累计预算可能被反复耗尽；
    # 一旦响应永远匹配不上（例如页面正在导航、事件流不断涌入），
    # 单个调用可能长时间不返回，因此需要总时长上限。
    # 实现方式：整个调用共享一个 $deadline，超时立即抛错。
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        # 单条消息的等待时间也不能超过剩余总预算
        $remainMs = [int][Math]::Max(500, ($deadline - (Get-Date)).TotalMilliseconds)
        $perRead = [Math]::Min(15000, $remainMs)

        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 262144
        while ($true) {
            $recv = $Session.Ws.ReceiveAsync(
                (New-Object System.ArraySegment[byte] -ArgumentList @(, $buf)),
                [System.Threading.CancellationToken]::None
            )
            if (-not $recv.Wait($perRead)) { throw "CDP 接收超时: $Method（总预算 $TimeoutSeconds 秒）" }
            if ($recv.Result.Count -gt 0) { $ms.Write($buf, 0, $recv.Result.Count) }
            if ($recv.Result.EndOfMessage) { break }
        }
        $text = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        $ms.Dispose()

        if ($text -match ('"id":' + $want + '[,}]')) {
            $parsed = $text | ConvertFrom-Json
            $err = Get-CdpField -Object $parsed -Path 'error.message'
            if ($err) { Write-CdpDiag "CDP 错误 $Method -> $err" }
            return $parsed
        }
    }
    throw "CDP 未收到响应: $Method（总预算 $TimeoutSeconds 秒）"
}

function Invoke-CdpJs {
    <#
    .SYNOPSIS
        在指定执行上下文中求值 JavaScript。
    .PARAMETER Expression
        JS 表达式。建议用 JSON.stringify(...) 包装后返回，便于结构化取值。
    .PARAMETER ContextId
        执行上下文 id；0 表示顶层主世界。由 Get-FrameContext 获取。
    .PARAMETER NoAwait
        不等待返回的 Promise 兑现 —— 表达式一旦返回 Promise 就立即结束求值。
    .OUTPUTS
        PSCustomObject：Error（字符串或 $null）与 Value。
        调用方必须检查 Error，不要假设 Value 一定有值。
    .NOTES
        何时该用 -NoAwait ：
          video.play() 返回的 Promise 在视频真正开始播放前不会兑现，
          而学习通的视频往往要等加载。若用默认的 awaitPromise，这个求值会
          一直等待，进而把整条 CDP 连接拖住（后续所有命令都超时）。
          因此凡是"触发式"调用（play / pause / click）都应加 -NoAwait。
    .EXAMPLE
        $r = Invoke-CdpJs -Session $s -Expression 'document.title'
        if ($r.Error) { Write-RunnerLog $r.Error -Level WARN } else { $r.Value }
    .EXAMPLE
        # 触发播放：不要等 Promise
        Invoke-CdpJs -Session $s -Expression 'document.querySelector("video").play()' -ContextId $ctx -NoAwait
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Expression,
        [int]$ContextId = 0,
        [switch]$NoAwait
    )

    $params = @{
        expression    = $Expression
        returnByValue = $true
        awaitPromise  = (-not $NoAwait)
        userGesture   = $true     # 让 play() 等需要用户手势的 API 可用
    }
    if ($ContextId -gt 0) { $params.contextId = $ContextId }

    try {
        $resp = Send-Cdp -Session $Session -Method 'Runtime.evaluate' -Params $params
    } catch {
        return [pscustomobject]@{ Error = "CDP异常: $($_.Exception.Message)"; Value = $null }
    }

    $cdpError = Get-CdpField -Object $resp -Path 'error.message'
    if ($cdpError) { return [pscustomobject]@{ Error = "CDP: $cdpError"; Value = $null } }

    # 帧在页面导航后会失效，此时上下文不存在，属于可预期情况
    $exceptionText = Get-CdpField -Object $resp -Path 'result.exceptionDetails.text'
    if ($exceptionText) {
        $desc = Get-CdpField -Object $resp -Path 'result.result.description'
        if ($desc) { $exceptionText = "$exceptionText | $desc" }
        return [pscustomobject]@{ Error = "JS: $exceptionText"; Value = $null }
    }

    $value = Get-CdpField -Object $resp -Path 'result.result.value'
    return [pscustomobject]@{ Error = $null; Value = $value }
}

function ConvertFrom-JsonArray {
    <#
    .SYNOPSIS
        把 JSON 数组字符串解析成对象数组（兼容 Windows PowerShell 5.1 与 7.x）。
    .DESCRIPTION
        必须单独一个函数的原因：
          Windows PowerShell 5.1 的 ConvertFrom-Json 遇到 JSON 数组时，
          返回的是"包装了数组的一个对象"（@(...) 只得到 1 个元素，且取属性为空），
          而不像 7.x 那样展开成多个对象。
          直接写 @($json | ConvertFrom-Json) 在 5.1 上会静默得到错误的元素个数，
          这类问题极难排查，所以统一走这里。
    .PARAMETER Json
        JSON 数组字符串。
    .OUTPUTS
        对象数组；解析失败或为空时返回空数组。
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()]$Json)

    if ($null -eq $Json -or "$Json" -eq '') { return @() }
    try {
        $parsed = ConvertFrom-Json -InputObject ([string]$Json)
    } catch {
        Write-CdpDiag "JSON 解析失败: $($_.Exception.Message)"
        return @()
    }
    return @(Expand-ToObjectArray -Value $parsed)
}

function Expand-ToObjectArray {
    <#
    .SYNOPSIS
        把 ConvertFrom-Json 的返回值规整成"元素数组"（内部辅助）。
    .NOTES
        两个必须绕开的坑（都只在 Windows PowerShell 5.1 上出现）：
          1) 写法 @($json | ConvertFrom-Json) 对 JSON 数组只会得到 1 个元素，
             必须用 -InputObject 传参；
          2) List[object].Add() 在绑定 Object[] 参数时会抛
             "Argument types do not match"（5.1 反射 bug），
             所以这里用数组拼接，不用泛型 List。
        改动前请先在 5.1 上运行 tests\check-jsonarray.ps1。
    #>
    [CmdletBinding()]
    param([AllowNull()]$Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value) }
    if ($Value -isnot [System.Collections.IEnumerable]) { return @($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return @($Value) }

    $result = @()
    foreach ($item in @($Value)) {
        if ($null -ne $item -and
            $item -is [System.Collections.IEnumerable] -and
            $item -isnot [string] -and
            $item -isnot [System.Collections.IDictionary] -and
            $item -isnot [System.Management.Automation.PSCustomObject]) {
            # 嵌套数组（5.1 的包装情形）：展开一层
            foreach ($inner in @($item)) { $result += $inner }
        } else {
            $result += $item
        }
    }
    return $result
}

function ConvertTo-JsLiteral {
    <#
    .SYNOPSIS
        把任意字符串安全地嵌进 JS 单引号字符串字面量。
    .NOTES
        选择器来自 Selectors.psd1，正常不会含引号；但拼接 JS 时
        统一走这里，避免日后有人往选择器里写了怪字符导致脚本注入。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)

    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) {
        switch ($ch) {
            "'" { [void]$sb.Append("\'") }
            '\' { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            default { [void]$sb.Append($ch) }
        }
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------- 帧与上下文

function Get-CdpFrames {
    <#
    .SYNOPSIS
        列出页面内所有 iframe（不含 about:blank）。
    .OUTPUTS
        对象数组，每项含 Id / Url / Depth。失败返回空数组。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $list = New-Object System.Collections.Generic.List[object]
    try {
        $resp = Send-Cdp -Session $Session -Method 'Page.getFrameTree' -Params @{}
    } catch {
        Write-CdpDiag "getFrameTree 失败: $($_.Exception.Message)"
        return $list
    }

    $tree = Get-CdpField -Object $resp -Path 'result.frameTree'
    if ($null -eq $tree) {
        Write-CdpDiag 'getFrameTree 响应缺少 frameTree'
        return $list
    }

    # 用递归函数遍历；childFrames 在叶子节点上不存在，必须判存在再遍历
    function Walk($node, $depth) {
        if ($null -eq $node) { return }
        $url = Get-CdpField -Object $node -Path 'frame.url'
        $id = Get-CdpField -Object $node -Path 'frame.id'
        if ($id -and $url -and $url -notmatch '^about:blank$') {
            $list.Add([pscustomobject]@{ Id = $id; Url = $url; Depth = $depth })
        }
        $children = Get-CdpField -Object $node -Path 'childFrames'
        if ($children) { foreach ($c in @($children)) { Walk $c ($depth + 1) } }
    }
    Walk $tree 0
    return $list
}

function Get-VideoFrameContexts {
    <#
    .SYNOPSIS
        列出这一节**所有**播放器帧的执行上下文 id。
    .DESCRIPTION
        为什么需要它：一节课可以有多个视频任务点，每个视频在自己的
        iframe 里（实测 1.4 节有两个 video 任务点，两个 ananas/modules/video 帧）。
        原来只用 Get-FrameContext 取第一个匹配的帧，于是播完第一个视频
        就以为整节完成了 —— 其余视频任务点没做，课节永远完不成。
    .PARAMETER Session
        CDP 会话。
    .PARAMETER UrlPattern
        播放器帧的 URL 特征。
    .OUTPUTS
        Int32[]：各播放器帧的 contextId，按页面顺序。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$UrlPattern
    )

    $result = New-Object System.Collections.ArrayList
    foreach ($f in (Get-CdpFrames -Session $Session)) {
        if ($f.Url -notmatch $UrlPattern) { continue }
        $ctx = 0
        try {
            $resp = Send-Cdp -Session $Session -Method 'Page.createIsolatedWorld' -Params @{
                frameId             = $f.Id
                worldName           = 'ccrvf' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
                grantUniveralAccess = $true
            }
            $ctx = [int](Get-CdpField -Object $resp -Path 'result.executionContextId')
        } catch {
            Write-CdpDiag ('Get-VideoFrameContexts: 建会话失败 ' + $f.Url + ' -> ' + $_.Exception.Message)
            continue
        }
        if ($ctx -gt 0) { [void]$result.Add($ctx) }
    }

    Write-CdpDiag ('Get-VideoFrameContexts: 命中 ' + $result.Count + ' 个播放器帧')
    return $result.ToArray()
}

function Find-VideoFrameContext {
    <#
    .SYNOPSIS
        找出"真正含 <video> 元素"的那个帧，返回其执行上下文 id。
    .DESCRIPTION
        为什么需要它：Get-FrameContext 靠 iframe 的 URL 特征匹配
        （例如 ananas/modules/video）。各学校的播放器路径不一样，
        一旦对不上，整节课就被判成"这一节没有视频"。

        这个函数不看 URL，而是挨个帧注入一段探测脚本，看里面有没有
        真的 <video>。代价是要多跑几轮 CDP，所以只在主路径失败时调用。

        探测时会顺带要求 video 有非零时长或已就绪：
        页面里常有隐藏的占位 <video>，光看标签存在会误判。
    .PARAMETER Session
        CDP 会话。
    .PARAMETER SkipPattern
        可选：URL 匹配它的帧跳过（一般不用）。
    .OUTPUTS
        Int32：contextId；找不到返回 0。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [string]$SkipPattern = ''
    )

    $probeJs = @'
(function(){
  var vs = document.querySelectorAll('video');
  if (!vs.length) return '0';
  for (var i = 0; i < vs.length; i++){
    var v = vs[i];
    // 只认"像样的"视频：有时长，或者已经加载出数据
    if ((v.duration && v.duration > 0) || v.readyState > 0) {
      return '1|' + Math.round(v.duration || 0) + '|' + v.readyState;
    }
  }
  // 有 video 但都没就绪，也算候选（可能还在加载）
  return '2|0|' + vs[0].readyState;
})()
'@

    foreach ($f in (Get-CdpFrames -Session $Session)) {
        if ($SkipPattern -and $f.Url -match $SkipPattern) { continue }
        # 顶层文档一般不是播放器所在，跳掉省一轮
        if (-not $f.Url -or $f.Url -eq 'about:blank') { continue }

        $ctx = 0
        try {
            $resp = Send-Cdp -Session $Session -Method 'Page.createIsolatedWorld' -Params @{
                frameId             = $f.Id
                worldName           = 'ccrv' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
                grantUniveralAccess = $true
            }
            $ctx = [int](Get-CdpField -Object $resp -Path 'result.executionContextId')
        } catch {
            continue
        }
        if ($ctx -le 0) { continue }

        $r = $null
        try { $r = Invoke-CdpJs -Session $Session -Expression $probeJs -ContextId $ctx } catch { $r = $null }
        if ($r -and -not $r.Error -and $r.Value) {
            $v = [string]$r.Value
            if ($v.StartsWith('1|') -or $v.StartsWith('2|')) {
                Write-CdpDiag ('按 video 元素找到播放器帧: ' + $f.Url +
                    '  探测=[' + $v + ']')
                return $ctx
            }
        }
    }

    Write-CdpDiag '遍历所有帧都没找到含 video 的帧'
    return 0
}

function Get-FrameContext {
    <#
    .SYNOPSIS
        在 URL 匹配 $UrlPattern 的 iframe 中创建一个隔离世界，返回其执行上下文 id。
    .PARAMETER UrlPattern
        匹配 iframe URL 的正则，例如 Selectors.psd1 里的 VideoFramePattern。
    .OUTPUTS
        Int32：contextId；找不到该帧或创建失败返回 0。
    .NOTES
        使用隔离世界（isolated world）有三个好处：
          1) 不污染页面自身的 JS 环境，页面检测不到我们注入的东西；
          2) 不受页面改写全局对象影响；
          3) grantUniveralAccess 让隔离世界仍能访问页面自身的 window 与 DOM。
        注意 "grantUniveralAccess" 的拼写是 CDP 协议本身的（少一个 s），
        改成正确拼写协议会不认。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$UrlPattern
    )

    $hit = $null
    foreach ($f in (Get-CdpFrames -Session $Session)) {
        if ($f.Url -match $UrlPattern) { $hit = $f; break }
    }
    if ($null -eq $hit) { return 0 }

    try {
        $resp = Send-Cdp -Session $Session -Method 'Page.createIsolatedWorld' -Params @{
            frameId             = $hit.Id
            worldName           = 'ccr' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
            grantUniveralAccess = $true
        }
        $ctx = Get-CdpField -Object $resp -Path 'result.executionContextId'
        if ($ctx) { return [int]$ctx }
        Write-CdpDiag "createIsolatedWorld 未返回 contextId (pattern=$UrlPattern)"
    } catch {
        Write-CdpDiag "createIsolatedWorld 失败 (pattern=$UrlPattern): $($_.Exception.Message)"
    }
    return 0
}

