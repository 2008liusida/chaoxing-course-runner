# 平台契约（DOM Contract）

> **这份文档是本项目最重要的维护资料。**
> 平台改版时，需要改的几乎只有 `lib/Selectors.psd1` 和这份文档。

---

## 一、为什么判据不看文字

学习通给课节标题套了一层名为 `font-cxsecret` 的字体（反爬措施）。
后果是：**DOM 里的 `innerText` 取出来是乱码**，真实字形由字体文件映射。

所以本项目**一律不用可见文字判断状态**，只用 id / class / 结构。
新增判据时请遵守这个原则，否则会在部分课程上莫名其妙失效。

---

## 二、页面结构

### 顶层文档（`studentstudy`）

```
<input id="curChapterId">    当前课节 id。权威来源，与地址栏 chapterId 一致。
                             判断"我在哪一节""切课成功了没"都以它为准。
<input id="curCourseId">     课程 id
<input id="curClazzId">      班级 id

<h5 id="cur<lessonId>">      每个课节一行
  └ 父容器 .ncells
      └ <span class="roundpoint ...">   状态圆点
                                       含 "orange" = 未完成；否则已完成
      └ <input class="jobUnfinishCount" value="1">  未完成任务点数（仅参考）

<button id="right1">         下一节
<button id="left1">          上一节
<a href="javascript:getTeacherAjax(courseId, clazzId, lessonId)">
                             目录里的课节链接，href 中含课节 id
```

**关于 `right1` 的坑**：课程树上的"章节"节点（例如 `2.1 第一课学习进步`）
也有 `right1`。点进去是一个**没有播放器的页面**。
因此不要用"点下一节"来推进流程，也不要只靠 URL 判断当前状态 ——
用地 `#curChapterId` + `h5[id^=cur]` 才可靠。

### iframe 三层

```
studentstudy                          ← 顶层：目录、curChapterId、right1
  └ knowledge/cards                   ← 内容层：任务点状态在这里
      └ ananas/modules/video          ← 播放器层：真正的 <video> 在这里
```

- 控制 `<video>` **必须**进到最里层（`ananas/modules/video`）
- 读取任务点完成状态在中间层（`knowledge/cards`）

### 内容层（`knowledge/cards`）

```
<div class="ans-job-icon ans-job-video ans-job-icon-clear">   任务点图标
     class 含 "clear" = 未完成
<div class="ans-job-finished">                                 已完成标记
     存在该元素 = 平台已登记完成（最可靠的完成信号）
```

---

## 三、工具用到的判据一览

学习通有**两个并行的课程页版本**，DOM 完全不同。`Selectors.psd1` 按版本分组，
运行时由 `PlatformDetect.psm1` 识别后合并成一张扁平表。

### 共用（`common` 区块）

| 用途 | 依据 | 选择器键名 |
|---|---|---|
| 切课兜底 | 页面全局函数 `getTeacherAjax` | `SwitchFunction` |
| 内容层帧 | iframe URL 特征 `knowledge/cards` | `CardsFramePattern` |
| 播放器层帧 | iframe URL 特征 `ananas/modules/video` | `VideoFramePattern` |
| 任务点图标 | class 含 `clear` | `JobIcon` / `JobIconClear` |
| 已完成 | 存在该元素 | `JobFinished` |
| 页面识别 | 任一命中即认为是课程页 | `PageFingerprints` |
| 登录判定 | 密码框 / passport 域 | `LoginPasswordInput` / `LoginUrlPattern` |
| 课程 / 班级 id | 隐藏 input 的值 | `CourseId` / `ClazzId` |

### 版本 A：`legacy`（主机 `mooc1-2.chaoxing.com`）

| 用途 | 依据 | 选择器键名 |
|---|---|---|
| 当前课节 | `<input id="curChapterId">` 的值 | `CurrentLessonId` |
| 课节列表 | `h5[id^=cur]` | `LessonNode` |
| 课节行容器 | 状态圆点的父容器 `.ncells` | `LessonRow` |
| 是否未完成 | 圆点 class 含 `orange` | `LessonStateDot` / `UnfinishedMark` |
| 切课 | 目录链接 href 含课节 id | `LessonLink` |

### 版本 B：`mooc2`（主机 `mooc1.chaoxing.com`，URL 带 `mooc2=1`）

| 用途 | 依据 | 选择器键名 |
|---|---|---|
| 课节列表 | `div.posCatalog_select` | `LessonNode` |
| 排除章标题 | class 含 `firstLayer` 的是"章"，不是课节 | `ChapterOnlyMark` |
| 课节 id | 条目 `id="cur<课节id>"`，去掉 `cur` 前缀 | `LessonIdPrefix` |
| 当前课节 | `div.posCatalog_active` | `ActiveMark` |
| 是否未完成 | 隐藏 input `jobUnfinishCount` 的值 > 0 | `UnfinishedCount` / `UnfinishedBy` |
| 目录位置 | 在与顶层同 URL 的 iframe 内 | `DirectoryInFrame` |

> **两个容易踩的点**
>
> 1. `mooc2` 版**顶层文档里没有** `#curChapterId`（它在 iframe 内）。
>    取当前课节必须用 `posCatalog_active`。
> 2. `mooc2` 的完成判据是 `jobUnfinishCount > 0`。
>    若某些课节该值恒为 1（已看过的课节仍显示 1），工具会重复播放它们。
>    这是当前判据的已知不足，欢迎在真实课程上补充样本后改进。

---

## 四、平台改版时的排查步骤

1. 在浏览器控制台里手工验证选择器：
   ```js
   document.querySelectorAll('h5[id^=cur]').length        // 应等于课节数
   document.getElementById('curChapterId').value           // 应等于地址栏 chapterId
   document.querySelector('.roundpoint').className         // 应含 orange 或 blue
   ```
2. 若 `h5[id^=cur]` 数量为 0，说明课节节点换了结构 —— 打开 Elements 面板
   找新的课节行，更新 `lib/Selectors.psd1` 的 `LessonNode` / `LessonRow`。
3. 若圆点 class 不再是 `orange`，更新 `UnfinishedMark`。
4. 若 iframe 路径变了，更新 `CardsFramePattern` / `VideoFramePattern`。
5. 改完运行 `tests/check-fixture.ps1`（夹具会一并暴露结构不匹配）。

> 提示：工具在"目录读到 0 节"或"求值失败"时会把**实际执行的 JS**
> 写进 `logs/run.log`（DEBUG 行），可以直接拿去控制台粘贴验证。

---

## 五、已知的平台行为

- **反爬字体**：`font-cxsecret`，导致 `innerText` 乱码。不要依赖文字。
- **完成条件**：不同课节要求不同，见过 90% 与 **100%** 两种；
  界面文案会写"观看时长需 ≥ 总时长的 N%"。
- **倍速**：平台会检测倍速，非 1 倍可能不计入时长，所以工具强制 1 倍速。
- **不可拖拽**：未完成任务点前进度条不可拖拽，所以工具只让播放器
  从头重播，不做 seek。
- **页面可见性**：完成条件里写明"观看时不可离开或将页面最小化"，
  所以默认保持浏览器前台（可用 `-NoForeground` 关闭）。
- **iframe 导航会失效上下文**：每次切课后执行上下文都会变，
  工具每次重新解析帧，不做缓存。
