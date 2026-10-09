<#
    平台层之一：课程页状态与切课。

    这里只做"读"和"切"，不做任何流程决策（比如"该不该跳过这一节"）。
    流程决策留给调用方（Run.ps1）。

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

function Get-ChapterTree {
    <#
    .SYNOPSIS
        读出课程目录的章节结构（章 -> 节），带课节 id。
    .DESCRIPTION
        为什么需要它：Get-LessonList 给的是平铺的课节列表，没有章节归属。
        使用者往往只想听某几章，或者从某一节听到另一节，所以得先把层级读出来。

        结构取自目录容器：章是 class 含 "cells" 的块，节是它里面的
        "ncells"。这个结构在 legacy / coursetree 两版里一致
        （mooc2 版目录在 iframe 内且是三层，走另一条路，见 Selectors.psd1）。

        章的标题取该块内第一个标题元素的文字；某些课程章块本身带课节 id，
        那种情况下章的首节就是它，也要算进去，不能漏。
    .PARAMETER Session
        CDP 会话。
    .PARAMETER Selectors
        合并后的扁平选择器表。
    .PARAMETER DirContextId
        目录所在执行上下文；顶层为 0。
    .OUTPUTS
        PSCustomObject：@{ ChapterCount; Chapters }
        Chapters 为 @{ Index; Title; LessonCount; Lessons }，
        Lessons 为 @{ Index; Id; Title; UnfinishedCount; Unfinished }。
        返回对象而非数组，避免 PowerShell 展开数组的老问题。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][hashtable]$Selectors,
        [int]$DirContextId = 0
    )

    $nodeSel = [string]$Selectors.LessonNode
    $rowSel = if ($Selectors.ContainsKey('LessonRow')) { [string]$Selectors.LessonRow } else { '' }
    $cntSel = if ($Selectors.ContainsKey('UnfinishedCount')) { [string]$Selectors.UnfinishedCount } else { '' }
    $prefix = if ($Selectors.ContainsKey('LessonIdPrefix')) { [string]$Selectors.LessonIdPrefix } else { 'cur' }

    $rootSel = if ($Selectors.ContainsKey('DirectoryRoot')) { [string]$Selectors.DirectoryRoot } else { '' }
    # 兜底发现可能会报一个"章标记"（未知结构下靠结构推出来的 class 名）。
    # 已知版本不需要它 —— 它们各有特征 class，靠 isChapter 里的规则就能认。
    $chapterMark = if ($Selectors.ContainsKey('ChapterNodeMark')) { [string]$Selectors.ChapterNodeMark } else { '' }
    $n = ConvertTo-JsLiteral -Value $nodeSel
    $r = ConvertTo-JsLiteral -Value $rowSel
    $c = ConvertTo-JsLiteral -Value $cntSel
    $p2 = ConvertTo-JsLiteral -Value $prefix
    $rootSelJs = ConvertTo-JsLiteral -Value $rootSel
    $chapterMarkJs = ConvertTo-JsLiteral -Value $chapterMark

    $js = @"
(function(){
  var nodeSel = '$n', rowSel = '$r', cntSel = '$c', prefix = '$p2', rootSpec = '$rootSelJs';

  // 目录根：优先用选择器给的，其次找常见容器，最后退回 body
  var dirRoot = null;
  if (rootSpec) { try { dirRoot = document.querySelector(rootSpec); } catch(e) { dirRoot = null; } }
  if (!dirRoot) { dirRoot = document.querySelector('#coursetree') || document.body; }

  function txt(el, max){
    if (!el) return '';
    var s = (el.innerText || '').replace(/\s+/g, ' ').trim();
    return s.substring(0, max || 80);
  }

  // 是不是"章"：三种版本的章各有特征，逐个试
  function isChapter(el){
    var cls = ' ' + String(el.className) + ' ';
    // legacy / coursetree：div.cells（但节是 div.ncells，别认错）
    if (cls.indexOf(' cells ') >= 0 && cls.indexOf(' ncells ') < 0) return true;
    // mooc2：章与节同名，靠 firstLayer 区分
    if (cls.indexOf(' posCatalog_select ') >= 0 && cls.indexOf(' firstLayer ') >= 0) return true;
    // 未知结构：用兜底发现推出来的章标记
    if (chapterMark && cls.indexOf(' ' + chapterMark + ' ') >= 0) return true;
    return false;
  }

  // 是不是"课节"：id 带 cur 前缀最可靠；其次是有 jobUnfinishCount 的那一行
  function lessonIdOf(el){
    if (!el) return '';
    var id = String(el.id || '');
    if (id.indexOf(prefix) === 0 && id.length > prefix.length) {
      return id.substring(prefix.length);
    }
    var node = nodeSel ? el.querySelector(nodeSel) : null;
    if (node) {
      var nid = String(node.id || '');
      if (nid.indexOf(prefix) === 0 && nid.length > prefix.length) {
        return nid.substring(prefix.length);
      }
    }
    return '';
  }

  function isLesson(el){
    if (isChapter(el)) return false;
    return lessonIdOf(el) !== '';
  }

  function countOf(el){
    if (!cntSel) return -1;
    var c = el.querySelector(cntSel);
    if (!c && String(el.className).indexOf('posCatalog_select') >= 0) {
      // mooc2 的计数可能挂在紧邻的兄弟里
      var p = el.parentElement;
      if (p) c = p.querySelector(cntSel);
    }
    return c ? parseInt(c.value, 10) : -1;
  }

  // ---- 按文档顺序线性扫描 ----
  // 三种版本都是"章在前、它下面的节紧随其后"，所以顺序扫一遍就能分组，
  // 不必去猜 DOM 嵌套关系（那要针对每种版本写一套规则）。
  var items = [];
  if (rowSel) {
    var rs = dirRoot.querySelectorAll(rowSel);
    for (var a = 0; a < rs.length; a++) items.push(rs[a]);
  }
  if (nodeSel) {
    var ns = dirRoot.querySelectorAll(nodeSel);
    for (var b = 0; b < ns.length; b++){
      // 去重：节点可能已经被 rowSel 收进去了
      var dup = false;
      for (var d = 0; d < items.length; d++){ if (items[d] === ns[b]) { dup = true; break; } }
      if (!dup) items.push(ns[b]);
    }
  }
  // 章块也可能是 nodeSel 命中的（mooc2），补上
  var cs = dirRoot.querySelectorAll('div[class]');
  for (var e2 = 0; e2 < cs.length; e2++){
    if (!isChapter(cs[e2])) continue;
    var dup2 = false;
    for (var f = 0; f < items.length; f++){ if (items[f] === cs[e2]) { dup2 = true; break; } }
    if (!dup2) items.push(cs[e2]);
  }

  // 按文档顺序排。compareDocumentPosition 是标准做法，
  // 比拿 offsetTop 之类的布局信息可靠。
  items.sort(function(x, y){
    if (x === y) return 0;
    var r = x.compareDocumentPosition(y);
    if (r & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
    if (r & Node.DOCUMENT_POSITION_PRECEDING) return 1;
    return 0;
  });

  var out = [];
  var cur = null;
  var seenId = {};

  for (var i = 0; i < items.length; i++){
    var el = items[i];
    if (isChapter(el)) {
      cur = { Title: txt(el, 60), Lessons: [] };
      out.push(cur);
      continue;
    }
    var id = lessonIdOf(el);
    if (!id) continue;
    if (seenId[id]) continue;
    seenId[id] = 1;
    if (!cur) { cur = { Title: '(未分章)', Lessons: [] }; out.push(cur); }
    cur.Lessons.push({
      Id: id,
      Title: txt(el, 70),
      UnfinishedCount: countOf(el)
    });
  }

  // 一个课节都没扫到：退回"整份目录当一章"，至少别返回空
  var total = 0;
  for (var k = 0; k < out.length; k++) total += out[k].Lessons.length;
  if (total === 0) {
    var all = nodeSel ? dirRoot.querySelectorAll(nodeSel) : [];
    var flat = [];
    for (var m = 0; m < all.length; m++){
      var fid = lessonIdOf(all[m]);
      if (!fid || seenId[fid]) continue;
      seenId[fid] = 1;
      flat.push({ Id: fid, Title: txt(all[m], 70), UnfinishedCount: countOf(all[m]) });
    }
    if (flat.length) out = [{ Title: '(全部章节)', Lessons: flat }];
  }

  return JSON.stringify(out);
})()
"@

    $r2 = Invoke-CdpJs -Session $Session -Expression $js -ContextId $DirContextId
    if ($r2.Error -or -not $r2.Value) {
        Write-CdpDiag ('Get-ChapterTree 读取失败: ' + $r2.Error)
        return [pscustomobject]@{ ChapterCount = 0; Chapters = @() }
    }
    # 解析 JSON。
    # 注意不要写成 @($r2.Value | ConvertFrom-Json) —— 那样会多包一层：
    # 拿到的是"一个元素，里面是整个章节数组"，于是 4 章被当成 1 章。
    # 这个坑本项目已经踩过三次（另两次在 Get-CdpTargets 与
    # 输出目标数组的地方），一律用"先赋值再判断"的写法。
    $parsed = $null
    try { $parsed = $r2.Value | ConvertFrom-Json } catch {
        Write-CdpDiag ('Get-ChapterTree 解析失败: ' + $_.Exception.Message)
        return [pscustomobject]@{ ChapterCount = 0; Chapters = @() }
    }
    if ($null -eq $parsed) {
        return [pscustomobject]@{ ChapterCount = 0; Chapters = @() }
    }
    # 只有一个章时 ConvertFrom-Json 给的是单个对象而不是数组，统一成数组
    $raw = if ($parsed -is [array]) { $parsed } else { @($parsed) }

    # 返回一个对象而不是数组。
    # PowerShell 的 return 会把数组展开，调用方再用 @() 包一层就变成
    # "一个装着数组的元素"，$tree.Count 得到 1 而不是章数 —— 这个坑
    # 本项目踩过两次（另一次在 Get-CdpTargets）。装进属性里最省心。
    $chapters = @()
    $ci = 0
    foreach ($ch in $raw) {
        $ci++
        $lessonList = @()
        $li = 0
        foreach ($l in @($ch.Lessons)) {
            $li++
            $lessonList += [pscustomobject]@{
                Index           = $li
                Id              = [string]$l.Id
                Title           = [string]$l.Title
                UnfinishedCount = [int]$l.UnfinishedCount
                Unfinished      = ([int]$l.UnfinishedCount -gt 0)
            }
        }
        $chapters += [pscustomobject]@{
            Index       = $ci
            Title       = [string]$ch.Title
            LessonCount = $lessonList.Count
            Lessons     = $lessonList
        }
    }

    return [pscustomobject]@{
        ChapterCount = $chapters.Count
        Chapters     = $chapters
    }
}

function Resolve-LessonRange {
    <#
    .SYNOPSIS
        把使用者给的范围描述解析成课节 id 列表。
    .DESCRIPTION
        支持三种写法，都作用在课程目录的层级上：
            章号         "2"        第 2 章全部
            章.节        "2.1"      第 2 章第 1 节
            课节序号     "7"        目录里第 7 节（当章号不存在时按序号理解）
        起点默认第一章第一节，终点默认最后一节。

        为什么按"章.节"而不是课节 id：使用者看的是目录，
        记住的是"1.3 向量的内积"这种名字，不是 1260026233。

        编号从目录标题里解析：标题形如 "1 1.3 向量的内积" 或 "3.1 仿射坐标变换"，
        取其中形如 X.Y 的那一段。解析不出来时退回按序号。
    .PARAMETER Chapters
        Get-ChapterTree 的 Chapters。
    .PARAMETER From
        起点描述，空 = 第一节。
    .PARAMETER To
        终点描述，空 = 最后一节。
    .OUTPUTS
        PSCustomObject：@{ Ok; LessonIds; FromText; ToText; Message }
        Ok=$false 时 Message 说明哪里没解析出来。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Chapters,
        [string]$From = '',
        [string]$To = ''
    )

    # 把目录摊平成一行一节的列表，并给每节算一个"章.节"编号
    $flat = @()
    $seq = 0
    foreach ($ch in $Chapters) {
        $chNo = [string]$ch.Index
        $secInCh = 0
        foreach ($l in $ch.Lessons) {
            $secInCh++
            $seq++
            # 从标题里抠 "X.Y" 形式的编号
            $label = ''
            if ([string]$l.Title -match '(\d+\.\d+)') { $label = $Matches[1] }
            if (-not $label) { $label = $chNo + '.' + $secInCh }
            $flat += [pscustomobject]@{
                Seq       = $seq
                Chapter   = [int]$ch.Index
                Section   = $secInCh
                Label     = $label
                Id        = [string]$l.Id
                Title     = [string]$l.Title
                ChapterName = [string]$ch.Title
            }
        }
    }
    if ($flat.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; LessonIds = @(); FromText = ''; ToText = ''; Message = '目录是空的' }
    }

    # 把一个描述解析成摊平列表里的下标（找不到返回 -1）
    function Find-Index {
        param([string]$Text)
        if ([string]::IsNullOrWhiteSpace($Text)) { return -1 }
        $s = $Text.Trim()

        # 1) "章.节"
        if ($s -match '^(\d+)\.(\d+)$') {
            $cn = [int]$Matches[1]; $sn = [int]$Matches[2]
            for ($i = 0; $i -lt $flat.Count; $i++) {
                if ($flat[$i].Chapter -eq $cn -and $flat[$i].Section -eq $sn) { return $i }
            }
            # 该章可能只有一节、且标题没带编号
            for ($i = 0; $i -lt $flat.Count; $i++) {
                if ($flat[$i].Label -eq $s) { return $i }
            }
            return -1
        }

        # 2) 纯章号：定位到该章第一节
        if ($s -match '^(\d+)$') {
            $num = [int]$Matches[1]
            for ($i = 0; $i -lt $flat.Count; $i++) {
                if ($flat[$i].Chapter -eq $num -and $flat[$i].Section -eq 1) { return $i }
            }
            # 该章不存在 -> 当序号用（1 起）
            if ($num -ge 1 -and $num -le $flat.Count) { return ($num - 1) }
            return -1
        }

        # 3) 直接给课节 id
        for ($i = 0; $i -lt $flat.Count; $i++) {
            if ($flat[$i].Id -eq $s) { return $i }
        }
        # 4) 标题片段匹配（唯一命中才算）
        $hit = -1; $n = 0
        for ($i = 0; $i -lt $flat.Count; $i++) {
            if ($flat[$i].Title -like ('*' + $s + '*')) { $hit = $i; $n++ }
        }
        if ($n -eq 1) { return $hit }
        return -1
    }

    $iFrom = Find-Index -Text $From
    $iTo = Find-Index -Text $To

    if (-not [string]::IsNullOrWhiteSpace($From) -and $iFrom -lt 0) {
        return [pscustomobject]@{ Ok = $false; LessonIds = @(); FromText = $From; ToText = $To
            Message = ('起点 "' + $From + '" 在目录里找不到。可以写章号(2)、章.节(2.1)、或目录序号。') }
    }
    if (-not [string]::IsNullOrWhiteSpace($To) -and $iTo -lt 0) {
        return [pscustomobject]@{ Ok = $false; LessonIds = @(); FromText = $From; ToText = $To
            Message = ('终点 "' + $To + '" 在目录里找不到。') }
    }

    if ($iFrom -lt 0) { $iFrom = 0 }
    if ($iTo -lt 0) { $iTo = $flat.Count - 1 }
    if ($iTo -lt $iFrom) {
        return [pscustomobject]@{ Ok = $false; LessonIds = @(); FromText = $From; ToText = $To
            Message = '终点排在起点前面了。' }
    }

    $ids = @()
    for ($i = $iFrom; $i -le $iTo; $i++) { $ids += $flat[$i].Id }

    return [pscustomobject]@{
        Ok        = $true
        LessonIds = $ids
        FromText  = ($flat[$iFrom].Label + ' ' + $flat[$iFrom].Title)
        ToText    = ($flat[$iTo].Label + ' ' + $flat[$iTo].Title)
        Message   = ''
    }
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
    // 状态标记不在课节节点自身里，而在它所在的那一行里：
    //   legacy: <div class="ncells"><h5 id="cur...">标题</h5>
    //             <span class="roundpoint orange01"></span></div>
    //   mooc2 : 同一条目内带 <input class="jobUnfinishCount">
    // 所以必须先找到行容器再往下查。
    //
    // 这里不能只查直接父节点 —— 真实页面里课节节点外面可能还套着一两层。
    // 做法是逐级向上找：哪一级能查到状态标记，就用哪一级。
    // 找不到就退回节点自身（兼容标记确实内嵌的结构）。
    var unfinished = false;
    var rawState = '';
    var unfinishCount = -1;

    // 行容器：只取课节节点的直接父节点，不向上爬。
    // 爬升会撞上"整章容器"（里面装着 5~6 节），在那里面查状态会读到别的课节。
    var row = node.parentElement || node;

    // ---- 状态标记从哪儿找 ----
    // 实测结构：课节自己的计数与徽标都在课节节点**内部**：
    //     <div class="ncells">
    //       <h4 id="cur1260026233" class="currents">
    //         <input type="hidden" class="jobUnfinishCount" value="1">
    //         <span class="roundpointStudent orange01 jobCount">1</span>
    //         <a ...><span>1.3 向量的内积</span></a>
    //       </h4>
    //     </div>
    // 已完成的节：h4 里既没有计数 input，也没有 jobCount 徽标。
    //
    // 所以判定要在**课节节点自身**范围内做，绝不能在整个行容器里查 ——
    // 行容器里一旦装着别的课节，读到的就是别人的计数（踩过这个坑：
    // 爬升到整章容器读到别的节的计数，已完成的节被判成未完成，反复重刷）。
    function stateScope() {
      // 优先课节节点自身；它内部没有标记时再看行容器
      // （有些版本把标记放在行容器里、与标题同级）。
      var rowHas = null;
      if (row && row !== node) {
        try {
          rowHas = row.querySelector(S.UnfinishedCount || '') ;
        } catch (e) { rowHas = null; }
      }
      // 行容器里有，但课节节点里没有 -> 说明标记在行容器这一级
      if (rowHas && !node.querySelector(S.UnfinishedCount || '')) { return row; }
      return node;
    }
    var scope = stateScope();

    if (typeof S.LessonStateDot === 'string' && S.LessonStateDot) {
      var dot = null;
      try { dot = scope.querySelector(S.LessonStateDot); } catch (e) { }
      if (dot) {
        rawState = dot.className || '';
        if (S.UnfinishedMark) { unfinished = rawState.indexOf(S.UnfinishedMark) >= 0; }
      }
    }

    if (typeof S.UnfinishedCount === 'string' && S.UnfinishedCount) {
      var inp = null;
      try { inp = scope.querySelector(S.UnfinishedCount); } catch (e) { }
      if (inp) {
        var v = parseInt(inp.value, 10);
        if (!isNaN(v)) {
          unfinishCount = v;
          if (S.UnfinishedByMode === 'job-count') { unfinished = v > 0; }
          if (!rawState) { rawState = 'jobUnfinishCount=' + v; }
        }
      } else if (S.UnfinishedByMode === 'job-count') {
        // 这一范围里压根没有计数元素。
        // 实测平台就是这么做标记的：整节做完后，计数 input 与橙色徽标一起消失。
        // 所以"没有计数元素"= 已完成；不能当成"读不到、按未完成算" ——
        // 那样已完成的节每轮都会被重刷，永远刷不完。
        unfinishCount = 0;
        unfinished = false;
        if (!rawState) { rawState = '(无计数元素=已完成)'; }
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
    Get-ChapterTree, Resolve-LessonRange, `
    Get-LessonList, Get-LessonById, `
    Get-CurrentLessonId, Get-UrlLessonId, `
    Test-CoursePage, Test-LoggedIn, Test-OnLoginPage, Switch-Lesson, Wait-LessonCurrent, `
    Get-CourseId, Get-ClazzId
