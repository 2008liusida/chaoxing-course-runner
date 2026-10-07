<#
    模块清单：ChaoxingCourseRunner 库

    这里是**导出函数的唯一出处**。
    各子模块内部刻意不再写 Export-ModuleMember —— 两处都写迟早会失同步，
    而症状是"函数明明定义了却提示找不到"，很难查。

    新增函数的流程：
      1) 在对应 .psm1 里写 function
      2) 把函数名加到下面的 FunctionsToExport
      3) 跑 tests\module-smoke.ps1 确认导出正常

    分层（自上而下）：
      Run.ps1              流程编排：选课节 -> 播完 -> 切下一节
        Chaoxing.psm1      平台页面：目录、当前课节、切课
        Video.psm1         平台播放器：定位视频帧、驱动播放
        CdpClient.psm1     传输层：CDP over WebSocket（与平台无关）
        Browser.psm1       进程层：找到/启动/关闭调试浏览器
        Selectors.psm1     DOM 契约的加载与校验
        Settings.psm1      配置解析
        Logging.psm1       日志
#>
@{
    RootModule        = 'ChaoxingCourseRunner.psm1'
    ModuleVersion     = '2.1.0'
    GUID              = 'ab0643d5-7605-499f-9113-4a6f2d9d3f89'

    Author            = 'ChaoxingCourseRunner contributors'
    Copyright         = 'PolyForm Noncommercial License 1.0.0'
    Description       = '超星学习通课程页的读取、切课与视频播放控制（供 Run.ps1 使用）。'

    PowerShellVersion = '5.1'

    NestedModules     = @(
        'Logging.psm1'
        'Settings.psm1'
        'Selectors.psm1'
        'CdpClient.psm1'
        'Browser.psm1'
        'PlatformDetect.psm1'
        'Chaoxing.psm1'
        'PageVisibility.psm1'
        'LessonRunner.psm1'
        'Video.psm1'
    )

    FunctionsToExport = @(
        # ---- 日志与配置 ----
        'Write-RunnerLog'
        'Write-ProgressLine'
        'Invoke-ClearDataPrompt'
        'Clear-ProgressLine'
        'Read-RunnerConfigFile'
        'Get-RunnerSettings'

        # ---- 选择器契约 ----
        'Import-CourseSelectors'
        'Get-CourseSelector'
        'Resolve-Platform'
        'Merge-SelectorTable'
        'Test-DirectoryInContext'
        'Get-CommonSelector'
        'Invoke-Lesson'
        'Enable-LessonVideoPlayback'
        'Arrange-Windows'
        'Set-WindowHalf'
        'Get-WindowFrameInsets'
        'Get-TerminalWindowHandle'
        'Get-ScreenWorkArea'
        'Get-PageVisibility'
        'Read-CourseSelectorTable'

        # ---- CDP 传输层 ----
        'Get-CdpVersion'
        'Get-CdpTargets'
        'Select-CdpPage'
        'New-CdpSession'
        'Close-CdpSession'
        'Send-Cdp'
        'Invoke-CdpJs'
        'Get-CdpField'
        'Get-CdpFrames'
        'Get-FrameContext'
        'Set-CdpLogPath'
        'Write-CdpDiag'
        'ConvertTo-JsLiteral'
        'ConvertFrom-JsonArray'

        # ---- 浏览器进程 ----
        'Find-BrowserExe'
        'Start-DebugBrowser'
        'Stop-DebugBrowser'
        'Get-BrowserWindowHandle'
        'Set-BrowserForeground'

        # ---- 平台层：页面状态与切课 ----
        'Get-SelectorsJs'
        'Get-SelectorValue'
        'Get-LessonList'
        'Get-LessonById'
        'Get-CurrentLessonId'
        'Get-UrlLessonId'
        'Test-CoursePage'
        'Test-LoggedIn'
        'Test-OnLoginPage'
        'Switch-Lesson'
        'Wait-LessonCurrent'
        'Get-CourseId'
        'Get-ClazzId'

        # ---- 平台层：视频控制 ----
        'Get-VideoContext'
        'Get-CardsContext'
        'Get-VideoState'
        'Start-VideoPlayback'
        'Restart-Video'
        'Get-JobIconClass'
        'Test-JobFinished'

        # ---- 内部辅助（跨模块调用需要，故一并导出）----
        'Expand-ToObjectArray'
        'ConvertTo-RunnerValue'
        'ConvertTo-SelectorScalar'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
