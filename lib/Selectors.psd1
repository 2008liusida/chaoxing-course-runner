<#
    DOM 契约表（Selectors）

    ============================ 为什么单独一个文件 ============================
    这个工具所有"脆弱"的部分，都集中在"学习通页面长什么样"这件事上。
    平台一旦改版，需要修改的就是本文件；其余模块都是稳定的通用逻辑。

    ============================ 判据为什么不用文字 ============================
    学习通给课节标题套了名为 font-cxsecret 的反爬字体：DOM 里的 innerText
    取出来是乱码（真实字形由字体文件映射）。因此本工具一律只用
    id / class / 结构 判断状态，绝不依赖可见文本。改版时请保持这个原则。

    ============================ 已适配两个平台版本 ============================
    学习通存在两个并行的课程页版本，DOM 完全不同。这里按版本分组，
    每个版本一套选择器，运行时自动识别（见 lib\PlatformDetect.psm1）。

      版本 A  legacy   主机 mooc1-2.chaoxing.com
              目录在顶层文档；课节为 h5[id^=cur]；状态圆点为 span.roundpoint
              当前课节为 <input id="curChapterId">

      版本 B  mooc2    主机 mooc1.chaoxing.com，URL 带 mooc2=1
              目录在 iframe 内；课节为 div.posCatalog_select
              当前课节为 div.posCatalog_active，条目 id 形如 cur985239278
              "章"标题条目额外带 firstLayer 类（无任务点，须排除）

    两版共同点（可复用部分）：
      · iframe 三层结构：studentstudy -> knowledge/cards -> ananas/modules/video
      · 切课函数 getTeacherAjax(courseId, clazzId, chapterId)

    ============================ 关于 "grantUniveralAccess" ============================
    注意这个拼写是 CDP 协议本身的（Universal 少了一个 s），
    不是本项目的笔误。改成正确拼写会导致协议不认识该字段。
#>

@{
    # ============ 版本 A：legacy（mooc1-2.chaoxing.com）============
    legacy = @{
        # 当前课节 id。判"我在哪一节""切课成功了没"都以它为准。
        CurrentLessonId  = '#curChapterId'
        # 课节节点：id 形如 cur1222994220
        LessonNode       = 'h5[id^=cur]'
        # 课节节点所在的行容器（状态圆点在它里面）
        LessonRow        = '.ncells'
        # 状态圆点：class 含 UnfinishedMark 即未完成
        LessonStateDot   = '.roundpoint'
        UnfinishedMark   = 'orange'
        # 从节点 id 解析课节 id 时要剥掉的前缀
        LessonIdPrefix   = 'cur'
        # 目录是否位于 iframe 内
        DirectoryInFrame = $false
        # 目录里可点击的课节链接（href 内含课节 id）
        LessonLink       = 'a'
        # 判断"是否未完成"的方式：'state-dot' = 看圆点 class
        UnfinishedBy     = 'state-dot'
    }

    # ============ 版本 B：mooc2（mooc1.chaoxing.com，URL 带 mooc2=1）============
    mooc2 = @{
        # 目录条目
        LessonNode       = 'div.posCatalog_select'
        # class 含此标记的是"章"标题，不是课节，须排除
        ChapterOnlyMark  = 'firstLayer'
        # 当前课节的标记类
        ActiveMark       = 'posCatalog_active'
        # 未完成任务点数所在的隐藏 input
        UnfinishedCount  = 'input.jobUnfinishCount'
        LessonIdPrefix   = 'cur'
        DirectoryInFrame = $true
        # 判断"是否未完成"的方式：'job-count' = 看 jobUnfinishCount 的值
        #   注意：该版本里"已完成"的课节此值为 0，"有任务点"的为 1，
        #   因此用 > 0 作为未完成判据。见 docs\PLATFORM-CONTRACT.md 的说明。
        UnfinishedBy     = 'job-count'
    }

    # ============ 两版共用 ============
    common = @{
        CourseId         = '#curCourseId'
        ClazzId          = '#curClazzId'
        SwitchFunction   = 'getTeacherAjax'

        # 内容层 iframe 的 URL 特征
        CardsFramePattern = 'knowledge/cards'
        # 播放器层 iframe 的 URL 特征
        VideoFramePattern = 'ananas/modules/video'

        # 内容层：任务点状态
        JobIcon          = '.ans-job-icon'
        JobIconClear     = 'clear'      # 图标 class 含它 = 未完成
        JobFinished      = '.ans-job-finished'

        # 登录判定
        LoginPasswordInput = 'input[type=password]'
        LoginUrlPattern    = 'passport\d*\.chaoxing\.com'

        # 页面特征探测：任一命中即认为是课程页。
        # 不要写 'chaoxing.com' 之类的宽泛规则 ——
        # 同域下的"个人空间"页会误命中。
        PageFingerprints = @(
            '#curChapterId'
            'div.posCatalog_select'
            'h5[id^=cur]'
        )
    }
}
