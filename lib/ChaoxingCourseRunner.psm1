<#
    ChaoxingCourseRunner —— 库入口

    仅负责把 lib\ 下的子模块串起来；真正的实现分散在各个 .psm1 里。
    分层（自上而下）：

        Run.ps1            流程编排：选课节 -> 播完 -> 切下一节
          lib\Chaoxing.psm1  平台页面：目录、当前课节、切课
          lib\Video.psm1     平台播放器：定位视频帧、驱动播放
          lib\CdpClient.psm1 传输层：CDP over WebSocket（与平台无关）
          lib\Browser.psm1   进程层：找到/启动/关闭调试浏览器
          lib\Selectors.psm1 DOM 契约：所有选择器集中定义
          lib\Settings.psm1  配置解析
          lib\Logging.psm1   日志
#>

# 子模块由清单的 NestedModules 自动加载，这里无需再 Import-Module。
# 保留此文件是为了让模块有明确的入口，也方便日后添加初始化逻辑。
