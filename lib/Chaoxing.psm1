<#
    平台层之一：课程页状态与切课。

    这里只做"读"和"切"，不做任何流程决策（比如"该不该跳过这一节"）。
    流程决策留给调用方（Run.ps1 / Run-Interactive.ps1）。

    支持两个平台版本（由 lib\PlatformDetect.psm1 识别，差异在此消化）：
      legacy  课节为 h5[id^=cur]，状态圆点 span.roundpoint
      mooc2   课节为 div.posCatalog_select，当前课节 div.posCatalog_active

    所有函数都需要：
      -Selectors      已合并的扁平选择器表（含 Version 键）
      -DirContextId   目录所在的执行上下文 id（0 = 顶层文档）
#>

Set-StrictMode -Version Latest

# 跨模块依赖：ConvertTo-JsLiteral 定义在 CdpClient.psm1。
# 显式引用，避免依赖"调用方恰好已经加载过 CdpClient"这种隐式约定。
Import-Module (Join-Path $PSScriptRoot 'CdpClient.psm1') -Force -DisableNameChecking

function Get-SelectorsJs {
    <#
    .SYNOPSIS
        把选择器表转成一段 JS 变量声明（内部辅助）。
    .NOTES
        用 -f 加编号占位符，不要写成 "S.$name='...'" ——
        PowerShell 会把 "$name=" 当成变量名，生成坏代码。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Selectors)

    $names = @(
        'LessonNode', 'LessonRow', 'LessonStateDot', 'UnfinishedMark',
        'ChapterOnlyMark', 'ActiveMark', 'UnfinishedCount', 'LessonIdPrefix'
    )
    $pairs = @()
    foreach ($name in $names) {
        if (-not $Selectors.ContainsKey($name)) { continue }
        $value = ConvertTo-JsLiteral -Value ([string]$Selectors[$name])
        $pairs += ("{0}:'{1}'" -f $name, $value)
    }
    if ($pairs.Count -eq 0) { throw '选择器表里没有任何可用键，无法生成 JS' }

    # 判据模式也要传进 JS。它是 PowerShell 侧的值，必须显式插值 ——
    # 漏掉这一步会让浏览器报 "mode is not defined"。
    $mode = ''
    if ($Selectors.ContainsKey('UnfinishedBy')) { $mode = [string]$Selectors['UnfinishedBy'] }
    $pairs += ("UnfinishedByMode:'{0}'" -f (ConvertTo-JsLiteral -Value $mode))

    return 'var S={' + ($pairs -join ',') + '};'
}

function Get-LessonList {
    <#
    .SYNOPSIS
        读取课程目录里的全部课节（按页面顺序）。
    .PARAMETER DirContextId
        目录所在执行上下文 id（0 = 顶层）。
    .OUTPUTS
        对象数组，每项：
          Id               课节 id
          Title            课节标题（受反爬字体影响可能是乱码，仅供人工识别）
          Unfinished       是否未完成
          StateClass       原始状态信息（排障用）
          UnfinishedCount  未完成任务点数（mooc2 版本用）
          Active           是否为当前课节
    .NOTES
        "是否未完成"的判据随版本不同：
          legacy  看状态圆点 class 是否含 orange
          mooc2   看隐藏 input.jobUnfinishCount 是否 > 0
        标题不可靠是刻意的：状态判定只依据 class / 数值。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [int]$DirContextId = 0
    )

    $setup = Get-SelectorsJs -Selectors $Selectors

    $js = @"
(function () {
  $setup
  var out = [];
  var nodes = document.querySelectorAll(S.LessonNode);
  for (var i = 0; i < nodes.length; i++) {
    var node = nodes[i];
    var cls = node.className || '';

    // 章标题条目（只有层级、没有任务点）需要排除
    if (S.ChapterOnlyMark && cls.indexOf(S.ChapterOnlyMark) >= 0) { continue; }

    // ---- 课节 id ----
    var id = '';
    if (node.id && node.id.indexOf(S.LessonIdPrefix) === 0 && node.id.length > S.LessonIdPrefix.length) {
      id = node.id.substring(S.LessonIdPrefix.length);
    }
    if (!id) {
      var nameEl = node.querySelector('[onclick]');
      if (nameEl) {
        var oc = nameEl.getAttribute('onclick') || '';
        var m = oc.match(/,\s*'(\d+)'\s*\)/);
        if (m) { id = m[1]; }
      }
    }
    if (!id) { continue; }

    var title = (node.innerText || '').replace(/\s+/g, ' ').trim();

    // ---- 是否未完成 ----
    var unfinished = false;
    var rawState = '';
    var unfinishCount = -1;

    if (typeof S.LessonStateDot === 'string' && S.LessonStateDot) {
      var dot = node.querySelector(S.LessonStateDot);
      if (dot) {
        rawState = dot.className || '';
        if (S.UnfinishedMark) { unfinished = rawState.indexOf(S.UnfinishedMark) >= 0; }
      }
    }
    if (typeof S.UnfinishedCount === 'string' && S.UnfinishedCount) {
      var inp = node.querySelector(S.UnfinishedCount);
      if (inp) {
        var v = parseInt(inp.value, 10);
        if (!isNaN(v)) {
          unfinishCount = v;
          if (S.UnfinishedByMode === 'job-count') { unfinished = v > 0; }
          if (!rawState) { rawState = 'jobUnfinishCount=' + v; }
        }
      }
    }

    var active = false;
    if (typeof S.ActiveMark === 'string' && S.ActiveMark && cls.indexOf(S.ActiveMark) >= 0) { active = true; }

    out.push({
      Id: id,
      Title: title,
      Unfinished: unfinished,
      StateClass: rawState,
      UnfinishedCount: unfinishCount,
      Active: active
    });
  }
  return JSON.stringify(out);
})()
"@

    $r = Invoke-CdpJs -Session $Session -Expression $js -ContextId $DirContextId
    if ($r.Error) {
        Write-CdpDiag "Get-LessonList 求值失败: $($r.Error)"
        return @()
    }
    if ($null -eq $r.Value -or "$($r.Value)" -eq '') {
        Write-CdpDiag "Get-LessonList 返回空值。所用 JS:`n$js"
        return @()
    }

    $parsed = ConvertFrom-JsonArray -Json $r.Value
    if (@($parsed).Count -eq 0) {
        # 读到 0 节是"平台改版 / 选择器失效 / 页面未就绪"的典型症状。
        # 把原始返回与实际执行的 JS 记进日志，便于对照
        # docs\PLATFORM-CONTRACT.md 修 lib\Selectors.psd1。
        Write-CdpDiag "Get-LessonList 得到 0 节。原始返回: $($r.Value)"
        Write-CdpDiag "Get-LessonList 所用 JS:`n$js"
    }
    return $parsed
}

function Get-LessonById {
    <#
    .SYNOPSIS
        按 id 取单个课节；不存在返回 $null。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [Parameter(Mandatory)][string]$LessonId,
        [int]$DirContextId = 0
    )
    foreach ($l in (Get-LessonList -Session $Session -Selectors $Selectors -DirContextId $DirContextId)) {
        if ($l.Id -eq $LessonId) { return $l }
    }
    return $null
}

function Get-CurrentLessonId {
    <#
    .SYNOPSIS
        读取当前课节 id。
    .DESCRIPTION
        两版取值方式不同：
          legacy  <input id="curChapterId"> 的 value
          mooc2   div.posCatalog_active 的 id 去掉 cur 前缀
    .OUTPUTS
        String；读不到返回空字符串。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [int]$DirContextId = 0
    )

    # legacy：隐藏输入
    if ($Selectors.ContainsKey('CurrentLessonId') -and "$($Selectors['CurrentLessonId'])" -ne '') {
        $curSel = ConvertTo-JsLiteral -Value ([string]$Selectors['CurrentLessonId'])
        $r = Invoke-CdpJs -Session $Session -Expression "var e=document.querySelector('$curSel'); e&&e.value?e.value:''" -ContextId $DirContextId
        if (-not $r.Error -and "$($r.Value)" -ne '') { return [string]$r.Value }
    }

    # mooc2：活动条目的 id
    if ($Selectors.ContainsKey('ActiveMark') -and "$($Selectors['ActiveMark'])" -ne '') {
        $activeMark = ConvertTo-JsLiteral -Value ([string]$Selectors['ActiveMark'])
        $prefix = ConvertTo-JsLiteral -Value ([string]$Selectors['LessonIdPrefix'])
        $js = "var e=document.querySelector('.$activeMark'); e&&e.id?e.id.replace('$prefix',''):''"
        $r2 = Invoke-CdpJs -Session $Session -Expression $js -ContextId $DirContextId
        if (-not $r2.Error -and "$($r2.Value)" -ne '') { return [string]$r2.Value }
    }
    return ''
}

function Get-UrlLessonId {
    <#
    .SYNOPSIS
        从地址栏 URL 里解析 chapterId。
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $r = Invoke-CdpJs -Session $Session -Expression '(location.href.match(/chapterId=(\d+)/)||["",""])[1]'
    if ($r.Error) { return '' }
    return [string]$r.Value
}

function Get-SelectorValue {
    <#
    .SYNOPSIS
        取一个选择器值，兼容"已合并的扁平表"与"未合并的原始表"（内部辅助）。
    .DESCRIPTION
        原始表结构是 @{ legacy=@{}; mooc2=@{}; common=@{} }，
        而 common 里的键（如 PageFingerprints、LoginPasswordInput）在扁平表里是顶层键。
        调用方若图省事直接传了原始表，这里自动去 common 里找 ——
        避免出现"传错表 → 取值恒为空 → 判定永远失败"这种难查的问题。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Selectors,
        [Parameter(Mandatory)][string]$Name
    )
    if ($Selectors.ContainsKey($Name)) { return $Selectors[$Name] }
    if ($Selectors.ContainsKey('common') -and $Selectors['common'] -is [hashtable] -and $Selectors['common'].ContainsKey($Name)) {
        return $Selectors['common'][$Name]
    }
    return $null
}

function Test-CoursePage {
    <#
    .SYNOPSIS
        判断某次 CDP 会话对应的是不是学习通课程页。
    .DESCRIPTION
        依次检查 PageFingerprints 里的选择器，任一命中即返回 $true。
        顶层与所有 iframe 都会查 —— mooc2 版本的关键元素在 iframe 内。
    .NOTES
        不要用 URL 判断：同域下的"个人空间"页会误命中。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors
    )

    $fingerprints = Get-SelectorValue -Selectors $Selectors -Name 'PageFingerprints'
    $checks = @()
    foreach ($sel in @($fingerprints)) {
        if ([string]::IsNullOrWhiteSpace([string]$sel)) { continue }
        $js = ConvertTo-JsLiteral -Value ([string]$sel)
        $checks += "!!document.querySelector('$js')"
    }
    if ($checks.Count -eq 0) {
        Write-CdpDiag 'Test-CoursePage: 选择器里没有 PageFingerprints（传错选择器表？）'
        return $false
    }
    $expr = "String(" + ($checks -join ' || ') + ")"

    $r = Invoke-CdpJs -Session $Session -Expression $expr
    if (-not $r.Error -and "$($r.Value)" -eq 'true') { return $true }

    foreach ($frame in (Get-CdpFrames -Session $Session)) {
        $ctx = 0
        try {
            $iso = Send-Cdp -Session $Session -Method 'Page.createIsolatedWorld' -Params @{
                frameId             = $frame.Id
                worldName           = 'ccrpage' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
                grantUniveralAccess = $true
            }
            $ctx = [int](Get-CdpField -Object $iso -Path 'result.executionContextId')
        } catch { continue }
        if ($ctx -le 0) { continue }
        $ri = Invoke-CdpJs -Session $Session -Expression $expr -ContextId $ctx
        if (-not $ri.Error -and "$($ri.Value)" -eq 'true') { return $true }
    }
    return $false
}

function Test-LoggedIn {
    <#
    .SYNOPSIS
        判断当前标签页是否为"已登录的课程页"。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors
    )

    $pwdSel = ConvertTo-JsLiteral -Value (Get-SelectorValue -Selectors $Selectors -Name 'LoginPasswordInput')
    $js = "JSON.stringify({url:location.href,hasPwd:!!document.querySelector('$pwdSel')})"
    $r = Invoke-CdpJs -Session $Session -Expression $js
    if ($r.Error) { return $false }

    try {
        $o = $r.Value | ConvertFrom-Json
        if ($o.hasPwd) { return $false }
        if ($o.url -match (Get-SelectorValue -Selectors $Selectors -Name 'LoginUrlPattern')) { return $false }
    } catch { return $false }

    return (Test-CoursePage -Session $Session -Selectors $Selectors)
}

function Test-OnLoginPage {
    <#
    .SYNOPSIS
        判断当前标签页是否被跳到了学习通登录页。
    .DESCRIPTION
        用于识别"登录态过期"。这个判断很重要：
        平台踢掉登录后，切课会静默失败（页面跳到 passport 域），
        若不识别，工具会一直重试，直到撞上总时长上限。
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)

    $r = Invoke-CdpJs -Session $Session -Expression 'location.href'
    if ($r.Error) { return $false }
    $url = [string]$r.Value
    if ($url -match 'passport\d*\.chaoxing\.com') { return $true }
    if ($url -match '/login') { return $true }
    return $false
}

function Switch-Lesson {
    <#
    .SYNOPSIS
        切换到指定课节。
    .DESCRIPTION
        三条路径，按顺序尝试：
          1) 改写地址栏 chapterId 后整体导航（最稳，不依赖页面脚本）
          2) 在目录帧里调用 getTeacherAjax(courseId, clazzId, lessonId)
          3) 点击目录里带该 id 的条目
    .PARAMETER ForceClick
        跳过路径 1。
    .OUTPUTS
        String：'navigate' / 'function' / 'click' / 错误或失败原因。
        调用方应随后用 Wait-LessonCurrent 确认是否真的切过去了。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [Parameter(Mandatory)][string]$LessonId,
        [int]$DirContextId = 0,
        [switch]$ForceClick
    )

    if (-not $ForceClick) {
        $cur = Invoke-CdpJs -Session $Session -Expression 'location.href'
        if (-not $cur.Error -and $cur.Value -match 'chapterId=\d+') {
            $newUrl = [regex]::Replace([string]$cur.Value, 'chapterId=\d+', "chapterId=$LessonId")
            # 用 FireAndForget：整页导航会销毁页面上下文，响应可能永远不来。
            # 若在此等待并超时抛错，那条迟到的响应会留在 WebSocket 缓冲区，
            # 导致后续每次调用都读到陈旧响应、ID 对不上、会话彻底错乱
            # （一旦发生，后续所有切课都会连续失败）。
            # 切课是否成功由随后的 Wait-LessonCurrent 轮询确认。
            Send-Cdp -Session $Session -Method 'Page.navigate' -Params @{ url = $newUrl } -FireAndForget | Out-Null
            return 'navigate'
        }
    }

    $idJs = ConvertTo-JsLiteral -Value $LessonId
    $fnJs = ConvertTo-JsLiteral -Value ([string]$Selectors['SwitchFunction'])
    $courseIdJs = ConvertTo-JsLiteral -Value ([string]$Selectors['CourseId'])
    $clazzIdJs = ConvertTo-JsLiteral -Value ([string]$Selectors['ClazzId'])

    $fnCode = @"
(function () {
  var id = '$idJs';
  try {
    var c = document.querySelector('$courseIdJs');
    var z = document.querySelector('$clazzIdJs');
    var cid = c ? c.value : '';
    var zid = z ? z.value : '';
    if (!cid || !zid) { return 'NOVARS'; }
    var f = window['$fnJs'];
    if (typeof f !== 'function') { return 'NOFUNC'; }
    f(cid, zid, id);
    return 'function';
  } catch (e) { return 'ERR ' + e.message; }
})()
"@
    $r = Invoke-CdpJs -Session $Session -Expression $fnCode -ContextId $DirContextId
    if (-not $r.Error -and "$($r.Value)" -eq 'function') { return 'function' }

    $nodeSel = ConvertTo-JsLiteral -Value ([string]$Selectors['LessonNode'])
    $prefix = ConvertTo-JsLiteral -Value ([string]$Selectors['LessonIdPrefix'])
    $clickJs = @"
(function () {
  var id = '$idJs';
  var nodes = document.querySelectorAll('$nodeSel');
  for (var i = 0; i < nodes.length; i++) {
    var nid = (nodes[i].id || '').replace('$prefix', '');
    if (nid === id) {
      var target = nodes[i].querySelector('[onclick]') || nodes[i];
      target.click();
      return 'click';
    }
  }
  return 'NOTFOUND';
})()
"@
    $r3 = Invoke-CdpJs -Session $Session -Expression $clickJs -ContextId $DirContextId
    if ($r3.Error) { return $r3.Error }
    return [string]$r3.Value
}

function Wait-LessonCurrent {
    <#
    .SYNOPSIS
        轮询等待当前课节变成 $LessonId。
    .OUTPUTS
        Boolean
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [Parameter(Mandatory)][string]$LessonId,
        [int]$DirContextId = 0,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if ((Get-CurrentLessonId -Session $Session -Selectors $Selectors -DirContextId $DirContextId) -eq $LessonId) { return $true }
    }
    return $false
}

function Get-CourseId {
    <#
    .SYNOPSIS
        读取课程 id（用于切课与日志）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [int]$DirContextId = 0
    )
    $sel = ConvertTo-JsLiteral -Value ([string]$Selectors['CourseId'])
    $r = Invoke-CdpJs -Session $Session -Expression "var e=document.querySelector('$sel'); e&&e.value?e.value:''" -ContextId $DirContextId
    if ($r.Error) { return '' }
    return [string]$r.Value
}

function Get-ClazzId {
    <#
    .SYNOPSIS
        读取班级 id（用于切课与日志）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [int]$DirContextId = 0
    )
    $sel = ConvertTo-JsLiteral -Value ([string]$Selectors['ClazzId'])
    $r = Invoke-CdpJs -Session $Session -Expression "var e=document.querySelector('$sel'); e&&e.value?e.value:''" -ContextId $DirContextId
    if ($r.Error) { return '' }
    return [string]$r.Value
}

Export-ModuleMember -Function `
    Get-SelectorsJs, Get-SelectorValue, `
    Get-LessonList, Get-LessonById, Get-CurrentLessonId, Get-UrlLessonId, `
    Test-CoursePage, Test-LoggedIn, Test-OnLoginPage, Switch-Lesson, Wait-LessonCurrent, `
    Get-CourseId, Get-ClazzId
