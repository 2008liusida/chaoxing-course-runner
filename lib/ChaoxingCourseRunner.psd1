<#
    模块清单：ChaoxingCourseRunner 库

    导出分两步，缺一不可：
      1) 子模块（NestedModules）内部的 Export-ModuleMember 决定它导出什么，
         清单才能汇总到 —— 少了它，函数定义了也提示找不到。
      2) 下面 FunctionsToExport 是最终对外的清单。
    两处都要改，容易漏。所以 tests\module-smoke.ps1 会核对
    "所有 Write-* / 公开函数是否真的能用"，漏加会直接测失败。

    注意：不要用 RequiredAssemblies 加载 CcrWin32.dll。
    那会在模块导入阶段就加载，一旦被拒（例如 .NET 的 CAS 把 DLL 判为
    来自网络位置）整个模块导入失败，什么都跑不起来。
    改由 lib\PageVisibility.psm1 与 lib\Browser.psm1 内部按需加载，
    加载不了还能退回运行时 Add-Type，功能降级而不是整体崩溃。

    新增函数的流程：
      1) 在对应 .psm1 里写 function
      2) 该文件末尾的 Export-ModuleMember 里加上函数名
      3) 把函数名加到下面的 FunctionsToExport
      4) 跑 tests\module-smoke.ps1 确认导出正常

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
        'Clear-ProgressLine'
        'Write-ConsoleLine'
        'Test-PageLoaded'
        'Invoke-CdpNavigate'
        'Find-VideoFrameContext'
        'Get-VideoFrameContexts'
        'Get-VideoFrames'
        'Get-FrameContextById'
        'Get-AllVideoContexts'
        'Select-NextVideoContext'
        'Get-JobStates'
        'Read-RunnerConfigFile'
        'Get-RunnerSettings'

        # ---- 选择器契约 ----
        'Import-CourseSelectors'
        'Get-CourseSelector'
        'Resolve-Platform'
        'Discover-CoursePage'
        'Merge-SelectorTable'
        'Test-DirectoryInContext'
        'Get-CommonSelector'
        'Invoke-Lesson'
        'Enable-LessonVideoPlayback'
        'Arrange-Windows'
        'Arrange-WindowsVerified'
        'Set-WindowHalf'
        'Set-TerminalWindowPlacement'
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
        'Get-ChapterTree'
        'Resolve-LessonRange'
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
