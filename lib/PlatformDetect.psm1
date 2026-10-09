<#
    平台版本识别。

    学习通存在两个并行的课程页版本，DOM 完全不同：

      legacy  mooc1-2.chaoxing.com
              目录在顶层文档，课节为 h5[id^=cur]，状态圆点 span.roundpoint

      mooc2   mooc1.chaoxing.com（URL 带 mooc2=1）
              目录在 iframe 内，课节为 div.posCatalog_select

    本模块负责：
      1. 判断当前页面是哪个版本
      2. 找出"目录所在的那个执行上下文"（可能是顶层，也可能是 iframe）
      3. 把 common + 对应版本的选择器合并成一张扁平表，交给其它模块使用

    为什么需要"扁平表"：
      Chaoxing.psm1 / Video.psm1 只想要一张直接取用的键值表，
      不应该关心版本分组的细节。版本差异在本模块内被消化掉。
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'CdpClient.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Selectors.psm1') -Force -DisableNameChecking

function Merge-SelectorTable {
    <#
    .SYNOPSIS
        把 common 与某个版本的选择器合并成一张扁平表（内部辅助）。
    .NOTES
        版本块优先：同名键以版本块为准。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Raw,
        [Parameter(Mandatory)][string]$VersionName
    )

    if (-not $Raw.ContainsKey($VersionName)) { throw "选择器表里没有版本: $VersionName" }
    if (-not $Raw.ContainsKey('common')) { throw '选择器表缺少 common 区块' }

    $flat = @{}
    foreach ($k in $Raw.common.Keys) { $flat[$k] = $Raw.common[$k] }
    foreach ($k in $Raw[$VersionName].Keys) { $flat[$k] = $Raw[$VersionName][$k] }
    $flat['Version'] = $VersionName
    return $flat
}

function Test-DirectoryInContext {
    <#
    .SYNOPSIS
        在给定执行上下文里探测：是否含课节目录，以及是哪个版本（内部辅助）。
    .PARAMETER ContextId
        执行上下文 id；0 表示顶层主世界。
    .OUTPUTS
        Hashtable：@{ Coursetree = <int>; Legacy = <int>; Mooc2 = <int> }（各自命中元素数量）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [int]$ContextId = 0
    )

    $expr = 'JSON.stringify({Coursetree:document.querySelectorAll("h4[id^=cur]").length,Legacy:document.querySelectorAll("h5[id^=cur]").length,Mooc2:document.querySelectorAll("div.posCatalog_select").length,HasCur:!!document.getElementById("curChapterId")})'
    $r = Invoke-CdpJs -Session $Session -Expression $expr -ContextId $ContextId
    $empty = @{ Coursetree = 0; Legacy = 0; Mooc2 = 0; HasCur = $false }
    if ($r.Error -or -not $r.Value) { return $empty }
    try {
        $o = $r.Value | ConvertFrom-Json
        return @{
            Coursetree = [int]$o.Coursetree
            Legacy     = [int]$o.Legacy
            Mooc2      = [int]$o.Mooc2
            HasCur     = [bool]$o.HasCur
        }
    } catch {
        return $empty
    }
}

function Discover-CoursePage {
    <#
    .SYNOPSIS
        在"不认识版本"的课程页上，靠平台约定把目录结构找出来。
    .DESCRIPTION
        各版本的选择器是写死的，遇到新结构就会报"版本我不认识"直接退出。
        但学习通有几条跨版本稳定的约定，可以据此现场还原结构：

          1) 课节节点 id 形如 cur<数字>（三个已支持的版本都成立）
          2) 切课函数是 getTeacherAjax，且能从课节条目的 href/onclick
             里把真实名字抠出来（不写死）
          3) #curCourseId / #curClazzId / #curChapterId 三个隐藏输入
          4) 未完成计数在某个隐藏 input 里，值是小整数

        找到之后拼一份与既有版本同形的选择器表，交给原来的流程继续跑。
        这样遇到第四种结构是"尽力而为"，而不是"直接放弃"。

        找不到关键项（尤其是课节节点）时如实返回 Failed，说明缺什么，
        以便使用者把页面结构反馈过来。
    .PARAMETER Session
        CDP 会话。
    .PARAMETER RawSelectors
        Import-CourseSelectors 的原始返回，用来取 common 块的公共项。
    .PARAMETER DirContextId
        在哪个执行上下文里找；顶层为 0。
    .OUTPUTS
        PSCustomObject：
          Ok         是否成功拼出可用结构
          Version    固定为 'discovered'
          Selectors  拼出的扁平选择器表（Ok 时有效）
          Reasons    探测过程中的发现，便于排查与反馈
          Message    失败原因（Ok=$false 时）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$RawSelectors,
        [int]$DirContextId = 0
    )

    $notOk = {
        param($msg, $why)
        return [pscustomobject]@{
            Ok = $false; Version = ''; Selectors = $null
            Reasons = $why; Message = $msg
        }
    }

    $js = @'
(function(){
  var r = {};

  // ---- 1. 课节节点：id 形如 cur<数字>，排除隐藏 input ----
  var all = document.querySelectorAll('[id^="cur"]');
  var nodes = [];
  for (var i = 0; i < all.length; i++){
    var id = String(all[i].id || '');
    if (!/^cur\d+$/.test(id)) continue;
    if (all[i].tagName === 'INPUT') continue;
    nodes.push(all[i]);
  }
  r.lessonCount = nodes.length;
  if (nodes.length){
    r.lessonTag = nodes[0].tagName.toLowerCase();
    // 用一条能被 querySelectorAll 直接命中的选择器描述它们
    r.lessonSel = r.lessonTag + '[id^=cur]';
  }

  // ---- 2. 切课函数名：从课节条目的 href / onclick 里抠 ----
  var fnCount = {};
  var re = /([A-Za-z_$][\w$]*)\s*\(\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*,\s*['"]([^'"]*)['"]\s*\)/g;
  var scope = document.querySelectorAll('a[href], [onclick]');
  for (var k = 0; k < scope.length; k++){
    var src = String(scope[k].getAttribute('href') || '') + ' ' +
              String(scope[k].getAttribute('onclick') || '');
    var m;
    while ((m = re.exec(src)) !== null){ fnCount[m[1]] = (fnCount[m[1]] || 0) + 1; }
  }
  var bestFn = '', bestN = 0;
  for (var f in fnCount){ if (fnCount[f] > bestN){ bestN = fnCount[f]; bestFn = f; } }
  r.switchFunction = bestFn;
  r.switchHits = bestN;
  r.switchAll = fnCount;

  // ---- 3. 课程 / 班级 / 当前课节 ----
  function valOf(sel){
    var e = document.querySelector(sel);
    return e ? String(e.value || '') : '';
  }
  r.courseId = valOf('#curCourseId');
  r.clazzId  = valOf('#curClazzId');
  r.chapterId = valOf('#curChapterId');

  // ---- 4. 未完成计数输入：值是小整数的隐藏 input ----
  var hid = document.querySelectorAll('input[type=hidden]');
  var cntSel = '', cntSeen = 0, cntBest = '';
  var byClass = {};
  for (var h = 0; h < hid.length; h++){
    var v = String(hid[h].value || '');
    if (!/^\d{1,3}$/.test(v)) continue;
    var cn = String(hid[h].className || '').trim();
    if (!cn) continue;
    byClass[cn] = (byClass[cn] || 0) + 1;
    if (byClass[cn] > cntSeen){ cntSeen = byClass[cn]; cntBest = cn; }
  }
  // 取命中最多的那个 class 的第一个 token 作为选择器
  if (cntBest) cntSel = 'input.' + cntBest.split(/\s+/)[0];
  r.unfinishedCount = cntSel;
  r.countHits = cntSeen;

  // ---- 5. 任务点完成状态：aria-label 里写"已完成"/"未完成" ----
  var lab = document.querySelectorAll('[aria-label]');
  var jobSel = '', jobSeen = 0, jobBest = '';
  var byJobClass = {};
  for (var q = 0; q < lab.length; q++){
    var lb = String(lab[q].getAttribute('aria-label') || '');
    if (lb.indexOf('任务点') < 0) continue;
    var jc = String(lab[q].className || '').trim();
    if (!jc) continue;
    var key = jc.split(/\s+/).filter(function(x){ return x.indexOf('ans-job') === 0; })[0] || '';
    if (!key) continue;
    byJobClass[key] = (byJobClass[key] || 0) + 1;
    if (byJobClass[key] > jobSeen){ jobSeen = byJobClass[key]; jobBest = key; }
  }
  if (jobBest) jobSel = '.' + jobBest;
  r.jobIcon = jobSel;
  r.jobHits = jobSeen;

  // ---- 6. 目录容器：覆盖全部课节的最深祖先 ----
  var dirRoot = null;
  if (nodes.length){
    var p = nodes[0].parentElement;
    while (p){
      var n = 0;
      for (var z = 0; z < nodes.length; z++){ if (p.contains(nodes[z])) n++; }
      if (n === nodes.length){ dirRoot = p; break; }
      p = p.parentElement;
    }
  }
  r.directoryRoot = '';
  if (dirRoot){
    if (dirRoot.id) { r.directoryRoot = '#' + dirRoot.id; }
    else {
      var dc = String(dirRoot.className || '').trim();
      if (dc) { r.directoryRoot = '.' + dc.split(/\s+/)[0]; }
    }
  }

  // ---- 7. 找"行容器所在的层级"，并据此认章 ----
  // 课节节点外面常常还套着行容器：
  //     .treeBox
  //       ├─ div.treeHead        ← 章
  //       └─ div.lessonItem      ← 行容器
  //             └─ span#cur123      ← 课节节点
  // 所以不能只看 dirRoot.children 有没有 cur<数字>。
  // 做法：从课节节点往上走，找到第一个"每个子元素各自最多包一个课节"
  // 的祖先 —— 那一层就是行容器层；该层里不含课节的兄弟就是章。
  var chapterMark = '';
  var lessonRowSel = '';
  if (dirRoot && nodes.length){
    var lvl = nodes[0].parentElement;
    var rowLevel = null;
    while (lvl && lvl !== dirRoot.parentElement){
      var cs = lvl.children, each = true;
      for (var ai = 0; ai < cs.length; ai++){
        var cntIn = 0;
        for (var bi = 0; bi < nodes.length; bi++){ if (cs[ai].contains(nodes[bi])) cntIn++; }
        if (cntIn > 1) { each = false; break; }
      }
      if (each && cs.length > 0) {
        // 还要确认这一层确实"装下了"课节（否则可能只是某个小容器）
        var tot = 0;
        for (var ci = 0; ci < cs.length; ci++){
          for (var di = 0; di < nodes.length; di++){ if (cs[ci].contains(nodes[di])) { tot++; break; } }
        }
        if (tot >= 2 || cs.length >= 2) { rowLevel = lvl; break; }
      }
      lvl = lvl.parentElement;
    }
    // 找不到合适的一层就退回直接父节点
    if (!rowLevel) { rowLevel = nodes[0].parentElement; }

    if (rowLevel){
      // 行容器的 class 报回去，Get-ChapterTree 用它当 LessonRow
      var rl = String(rowLevel.className || '').trim();
      if (rl) { lessonRowSel = '.' + rl.split(/\s+/)[0]; }

      // 章与"行容器"同级，所以要在 rowLevel 的父级里找，
      // 而不是在 rowLevel.children（那是课节的兄弟层，永远找不到章）。
      var chapterLevel = rowLevel.parentElement || rowLevel;
      var sib = chapterLevel.children;
      for (var si = 0; si < sib.length; si++){
        var hasL = false;
        for (var ei = 0; ei < nodes.length; ei++){ if (sib[ei] && sib[si].contains(nodes[ei])) { hasL = true; break; } }
        if (hasL) continue;
        var sc = String(sib[si].className || '').trim();
        if (sc && (sib[si].innerText || '').trim().length > 1){
          chapterMark = sc.split(/\s+/)[0];
          break;
        }
      }
    }
  }
  r.chapterMark = chapterMark;
  r.lessonRowSel = lessonRowSel;

  return JSON.stringify(r);
})()
'@

    $r = Invoke-CdpJs -Session $Session -Expression $js -ContextId $DirContextId
    $reasons = @()
    if ($r.Error -or -not $r.Value) {
        return (& $notOk '在页面上探测结构时求值失败' @($r.Error))
    }
    try { $o = $r.Value | ConvertFrom-Json } catch {
        return (& $notOk '探测结果解析失败' @($_.Exception.Message))
    }

    $reasons += ('课节节点（cur<数字>）命中 ' + [int]$o.lessonCount + ' 个')
    $reasons += ('切课函数候选: ' + $(if ($o.switchFunction) { $o.switchFunction } else { '未找到' }))
    $reasons += ('未完成计数选择器: ' + $(if ($o.unfinishedCount) { $o.unfinishedCount } else { '未找到' }))
    $reasons += ('任务点状态选择器: ' + $(if ($o.jobIcon) { $o.jobIcon } else { '未找到' }))
    $reasons += ('目录容器: ' + $(if ($o.directoryRoot) { $o.directoryRoot } else { '未找到' }))
    $reasons += ('章标题标记: ' + $(if ($o.chapterMark) { $o.chapterMark } else { '未找到（目录将不分章）' }))
    $reasons += ('行容器选择器: ' + $(if ($o.lessonRowSel) { $o.lessonRowSel } else { '未找到' }))

    if ([int]$o.lessonCount -le 0) {
        return (& $notOk '页面上找不到任何课节节点（id 形如 cur<数字>）' $reasons)
    }
    if (-not $o.courseId -or -not $o.clazzId) {
        return (& $notOk '找不到 #curCourseId / #curClazzId，无法安全切课' $reasons)
    }

    # 拼一份与既有版本同形的选择器表
    $merged = @{}
    foreach ($k in $RawSelectors.common.Keys) { $merged[$k] = $RawSelectors.common[$k] }
    $merged['Version']          = 'discovered'
    $merged['LessonNode']       = [string]$o.lessonSel
    $merged['LessonIdPrefix']   = 'cur'
    $merged['CourseId']         = '#curCourseId'
    $merged['ClazzId']          = '#curClazzId'
    $merged['CurrentLessonId']  = '#curChapterId'
    $merged['SwitchFunction']   = $(if ($o.switchFunction) { [string]$o.switchFunction } else { 'getTeacherAjax' })
    $merged['DirectoryInFrame'] = $false
    if ($o.unfinishedCount) {
        $merged['UnfinishedCount'] = [string]$o.unfinishedCount
        $merged['UnfinishedBy']    = 'job-count'
    }
    if ($o.jobIcon) { $merged['JobIcon'] = [string]$o.jobIcon }
    if ($o.directoryRoot) { $merged['DirectoryRoot'] = [string]$o.directoryRoot }
    # 章标记交给 Get-ChapterTree 用：它按"遇到章开新组"来分组
    if ($o.chapterMark) { $merged['ChapterNodeMark'] = [string]$o.chapterMark }
    if ($o.lessonRowSel) { $merged['LessonRow'] = [string]$o.lessonRowSel }

    return [pscustomobject]@{
        Ok        = $true
        Version   = 'discovered'
        Selectors = $merged
        Reasons   = $reasons
        Message   = ''
    }
}

function Resolve-Platform {
    <#
    .SYNOPSIS
        识别平台版本，并定位"目录所在的执行上下文"。
    .PARAMETER Session
        CDP 会话（课程页所在标签页）。
    .PARAMETER RawSelectors
        Import-CourseSelectors 的原始返回（含 common 与各版本块）。
    .OUTPUTS
        PSCustomObject：
          Version       'legacy' / 'mooc2' / 'coursetree' / ''（识别失败）
          Selectors     合并后的扁平选择器表
          DirContextId  目录所在执行上下文 id（0 = 顶层）
          LegacyCount   legacy 课节节点数
          Mooc2Count    mooc2 目录条目数
          CoursetreeCount  coursetree 课节节点数
    .NOTES
        探测顺序：先看顶层，再逐个 iframe。
        两个版本都可能把目录放在 iframe 里，所以不能只查顶层。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$RawSelectors
    )

    $result = [pscustomobject]@{
        Version        = ''
        Selectors      = $null
        DirContextId   = 0
        LegacyCount    = 0
        Mooc2Count     = 0
        CoursetreeCount = 0
    }

    # ---- 1. 顶层 ----
    $top = Test-DirectoryInContext -Session $Session -ContextId 0

    # coursetree 要排在 legacy 前面判断：它同样带 #curChapterId，
    # 但课节节点是 h4。若先判 legacy，会因节点数是 0 而落到 mooc2 分支，
    # 最后报"不认识的版本"。
    if ($top.Coursetree -gt 0) {
        $result.Version = 'coursetree'
        $result.CoursetreeCount = $top.Coursetree
        $result.DirContextId = 0
        $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'coursetree'
        Write-CdpDiag ('检测到 coursetree 版本（课节节点 ' + $top.Coursetree + ' 个）')
        return $result
    }

    if ($top.Legacy -gt 0 -and $top.HasCur) {
        $result.Version = 'legacy'
        $result.LegacyCount = $top.Legacy
        $result.DirContextId = 0
        $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'legacy'
        return $result
    }
    if ($top.Mooc2 -gt 0) {
        $result.Version = 'mooc2'
        $result.Mooc2Count = $top.Mooc2
        $result.DirContextId = 0
        $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'mooc2'
        return $result
    }

    # ---- 2. 逐个 iframe ----
    foreach ($frame in (Get-CdpFrames -Session $Session)) {
        $ctx = 0
        try {
            $iso = Send-Cdp -Session $Session -Method 'Page.createIsolatedWorld' -Params @{
                frameId             = $frame.Id
                worldName           = 'ccrprobe' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
                grantUniveralAccess = $true
            }
            $ctx = [int](Get-CdpField -Object $iso -Path 'result.executionContextId')
        } catch { continue }
        if ($ctx -le 0) { continue }

        $probe = Test-DirectoryInContext -Session $Session -ContextId $ctx
        if ($probe.Mooc2 -gt 0) {
            $result.Version = 'mooc2'
            $result.Mooc2Count = $probe.Mooc2
            $result.DirContextId = $ctx
            $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'mooc2'
            Write-CdpDiag ("检测到 mooc2 版本，目录在帧内: " + $frame.Url)
            return $result
        }
        if ($probe.Legacy -gt 0 -and $probe.HasCur) {
            $result.Version = 'legacy'
            $result.LegacyCount = $probe.Legacy
            $result.DirContextId = $ctx
            $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'legacy'
            Write-CdpDiag ("检测到 legacy 版本，目录在帧内: " + $frame.Url)
            return $result
        }
    }

    # ---- 3. 识别失败：退回 legacy 选择器，让上层报"读不到目录" ----
    Write-CdpDiag '平台版本识别失败：顶层与所有帧都没找到课节目录'
    $result.Selectors = Merge-SelectorTable -Raw $RawSelectors -VersionName 'legacy'
    return $result
}

function Get-CommonSelector {
    <#
    .SYNOPSIS
        从扁平表里取一个键；不存在则抛错（早失败优于到处判空）。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Selectors,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $Selectors.ContainsKey($Name)) { throw "选择器不存在: $Name" }
    return $Selectors[$Name]
}

Export-ModuleMember -Function Resolve-Platform, Merge-SelectorTable, Test-DirectoryInContext, Get-CommonSelector, Discover-CoursePage
