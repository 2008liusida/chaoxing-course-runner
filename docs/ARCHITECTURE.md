# 架构

## 目录结构

```
chaoxing-runner/
├─ Start.bat                     主入口（双击即用）
├─ Run.ps1                       主流程编排
├─ Diagnose.bat                  环境自检（跑不起来时先双击这个）
├─ ClearCache.bat                清理浏览器缓存
├─ config.psd1                   使用者配置（唯一需要改的文件）
├─ lib/
│  ├─ ChaoxingCourseRunner.psd1 模块清单：导出函数的唯一出处
│  ├─ ChaoxingCourseRunner.psm1 模块入口（仅说明分层）
│  ├─ Logging.psm1              日志 + 单条进度条
│  ├─ Settings.psm1             配置解析与校验
│  ├─ Selectors.psd1            DOM 契约表（平台改版只需改这里）
│  ├─ Selectors.psm1            契约表的加载与校验
│  ├─ PlatformDetect.psm1       平台版本识别：legacy / mooc2
│  ├─ CdpClient.psm1            CDP over WebSocket（与平台无关）
│  ├─ Browser.psm1              浏览器进程：查找/启动/关闭/置前台
│  ├─ PageVisibility.psm1       页面可见性保障（视频能否加载的前提）
│  ├─ Chaoxing.psm1             平台页面：目录、当前课节、切课
│  ├─ Video.psm1                平台播放器：定位视频帧、驱动播放
│  └─ LessonRunner.psm1         单节课状态机（两个入口共用）
├─ scripts/Clear-Cache.ps1      清理缓存的实际逻辑（ClearCache.bat 调用）
├─ tests/                       离线自测（可删；含夹具与夹具配置）
├─ docs/                        本文档与平台契约
├─ browser-profile/             浏览器数据（自动生成，勿跨机拷贝）
└─ logs/                        运行日志
```

## 分层原则

**自上而下单向依赖**，上层知道下层，下层不知道上层：

```
Run.ps1                 流程决策：选哪些课节、播到什么时候停、要不要重播
  LessonRunner.psm1     单节课状态机：切课 -> 播放 -> 等登记。两个入口共用
    PlatformDetect.psm1 版本识别：判断页面是 legacy 还是 mooc2
    PageVisibility.psm1 可见性：窗口恢复 + 标签页激活（视频加载前提）
    Chaoxing.psm1       平台读/写：目录、当前课节、切课。不做流程决策
    Video.psm1          平台播放器原子操作：读状态、play、重播
    CdpClient.psm1      传输：发命令、收响应、进 iframe 求值。不懂超星
    Browser.psm1        进程：找浏览器、起调试端口、关进程
    Selectors.psm1      契约：加载并校验选择器表
    Settings.psm1       配置：默认值 + 文件 + 命令行 三层合并
    Logging.psm1        日志与进度条
```

判断某个函数该放哪一层，看它是否知道"超星"：

- 知道具体选择器、iframe 路径 → 平台层（Chaoxing / Video / PlatformDetect）
- 只知道 URL / CDP 协议 → 传输层（CdpClient）
- 不知道任何页面 → 进程层（Browser / PageVisibility）

> **为什么把 `LessonRunner` 单独抽出来**：单节课的状态机（切课→播放→等登记）
> 与"选哪些课节、什么时候停"属于不同层次的决策。分开后，
> 流程改动不必触碰播放细节，播放细节的修改也不会影响选课逻辑。

## 五个刻意的设计决定

### 1. 选择器集中在一个文件，并按平台版本分组

平台的 DOM 是最易变的部分。把所有选择器放进 `lib/Selectors.psd1`，
改版时改一个文件即可，不必在逻辑里搜散落的选择器字符串。

学习通有两个并行的课程页版本（`legacy` / `mooc2`），DOM 完全不同，
所以这个文件按版本分组，运行时由 `PlatformDetect.psm1` 识别后合并成一张扁平表。
**调用方只看到扁平表**，不需要关心版本差异。

`Chaoxing.psm1` / `Video.psm1` 的所有函数都要求显式传入 `-Selectors`，
不自己去找文件 —— 便于测试，也避免隐式全局状态。

### 2. 导出声明只有一处

导出函数只写在 `lib/ChaoxingCourseRunner.psd1` 的 `FunctionsToExport`。
子模块内部**不写** `Export-ModuleMember`。

原因：两处都写迟早会失同步，症状是"函数明明定义了却提示找不到"，
排查成本较高。新增函数时记得同步清单，
并跑 `tests/module-smoke.ps1` 确认导出正常。

### 3. 跨模块状态用环境变量而非模块变量

`Set-CdpLogPath` 用环境变量 `CCR_CDP_LOG` 传递日志路径，而不是
`$script:` 变量。

原因：PowerShell 的每个 `.psm1` 模块作用域独立。`Chaoxing.psm1` 里
`Import-Module CdpClient.psm1 -Force` 会得到一份**自己的实例**，
于是"设置一次、处处生效"不成立，诊断日志会静默丢失
（表现为"明明有失败，日志却是空的"）。

### 4. 会销毁页面上下文的命令用 FireAndForget

`Page.navigate` 会触发整页导航，页面上下文随之销毁，CDP 响应可能永远不来。

原来的实现等待响应并设超时，看起来合理，实际有两个坑：

1. 超时太短会把"其实已生效"的导航误判为失败
2. **更严重**：超时抛错中断了接收循环，但那条迟到的响应仍留在 WebSocket
   缓冲区没人读走。此后每个调用都会先读到它、ID 对不上，
   于是**整条会话错乱**，后续所有切课连续失败

所以对这类命令用 `Send-Cdp -FireAndForget`：发出后不等响应，
"到底成没成"交给状态轮询（`Wait-LessonCurrent`）确认。

**结论**：对会销毁上下文的命令，等待响应本身就是错的；
加大超时预算只是延长痛苦。

### 5. 播放进度只刷屏、不落盘；里程碑只落盘、不上屏

一节课的轮询会产生大量进度记录，会把
"完成 / 跳过 / 失败原因"这些关键事件淹没在噪声里。
所以进度走 `Write-ProgressLine` 就地刷新一行，不写文件。

**反过来也有一个坑**：里程碑原本同时输出到控制台，
而进度条靠回车符就地覆盖同一行 —— 中间插入任何一行输出，
后续进度就落到新行，表现为"进度条一行一行往下滚"。
现在里程碑用 `Write-RunnerLog -FileOnly` 只落盘，控制台保持单行刷新。

同一个传播路径还有一个隐患：**补位宽度不能写死**。
原先固定 110 字符，窗口比它窄时该行会折行，效果与上面一样。
现在读取终端实际宽度（留 1 字符余量），过宽则截断而不折行。

### 6. 状态判据一律用"正面确认"，不用"否定式"

等待类逻辑（等登录、等课程页）原先写成"没停在登录页就算登上了"。
这个判据在"什么都还没发生"时天然为真 ——
浏览器刚启动时标签页是 `about:blank`，不在登录页，
于是工具立刻判定已登录，随即因找不到页面而报错。

现在统一为**正面确认**：必须确认已到达目标状态才继续。
登录阶段由 `Get-LoginState` 返回三种状态：

| 状态 | 含义 | 是否继续 |
|---|---|---|
| `no-page` | 没有学习通页面（刚启动、跳转中、空白页） | 否 |
| `login` | 停在登录页 | 否 |
| `ready` | 确认停在真正的学习通页面且不在登录页 | **是** |

**结论**：写等待条件时不要写"不是什么"，要写"是什么"。
否定式判据在初始态就成立，会绕过整个等待。

## 控制台输出约定

| 项 | 约定 | 原因 |
|---|---|---|
| 时间戳与级别标签 | 只写文件，不上控制台 | 使用者看的是内容，前缀是噪音 |
| 级别区分 | 靠文字颜色（绿/黄/红/灰） | 不占宽度，一眼可辨 |
| 进度条 | 就地刷新，宽度自适应 | 写死宽度会在窄窗口折行 |
| 里程碑 | 只落盘 | 上屏会打断进度条的就地刷新 |
| 横幅 | 纯 ASCII 或字库原样输出 | 手拼艺术字在不同字体下会走样 |
| 启动段长度 | 控制在常见窗口可完整显示的范围内 | 内容被顶出屏幕等于没显示 |

## 执行流（单节课）

`LessonRunner.psm1 → Invoke-Lesson` 的状态机：

```
切课阶段（整体受 4 分钟上限约束）
  ├─ Resolve-Platform 已识别版本，取到合并后的选择器与目录上下文
  ├─ Switch-Lesson：优先改地址栏 chapterId（FireAndForget 发出即返回），
  │                 否则在目录帧调用 getTeacherAjax，再否则点目录条目
  ├─ Wait-LessonCurrent 轮询当前课节确认切换成功
  └─ 未成功 → 先判是否被踢到登录页（是则直接上报，不做无意义重试）
              → 否则重试一次 → 仍失败则跳过

播放循环（受 MaxWaitMinutesPerLesson 与停滞计数约束）
  ├─ Enable-LessonVideoPlayback：
  │      先读可见性 —— 已 visible 直接返回（不碰窗口、不等待）
  │      只有确实 hidden 时才：窗口级 ShowWindow 恢复
  │                          加 标签页级 Page.bringToFront
  │      ← 两步缺一不可，否则页面仍是 hidden
  │      ← 但不做 SetForegroundWindow：窗口可见即可，
  │        抢焦点只会妨碍使用者操作终端（启动时由 Arrange-Windows 摆到一侧）
  ├─ 找播放器层帧；找不到 → 计数，刷新一次，仍无则跳过该节
  ├─ 内容层已有 .ans-job-finished → 判定完成，退出
  ├─ 时长未知 → 调 play() 触发加载（学习通要靠 play 才加载）
  ├─ 暂停中 → 调 play()
  ├─ 速率被改 → 拉回 1.0
  ├─ 刷新进度条（Write-ProgressLine，不写文件）
  ├─ 每分钟往日志文件留一条里程碑（-FileOnly，不上屏）
  ├─ 停滞太久 → 重试 play；仍不动 → 放弃本节
  │     阈值按秒换算（60 秒重试 / 240 秒放弃），
  │     不随 PollSeconds 变化，否则改间隔会连带改容忍时长
  └─ 播到结尾 → 等平台登记（最多 40 秒）
       ├─ 登记成功 → 完成
       └─ 未登记 → 从头重播（MaxReplayPerLesson 次）
            └─ 仍未登记 → 跳过并记录
