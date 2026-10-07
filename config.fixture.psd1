# ！仅供离线自测使用，日常运行请改 config.psd1
# ============================================================
#  离线自测配置：对 tests\fixture 里的夹具页面运行
#
#  用途：不接触真实课程，验证"识别课节 / 切课 / 播放 / 任务点判定"链路。
#  用法见 README 的"离线自测"一节。
#
#  注意：夹具页是本地静态文件，URL 里没有 chapterId 参数，
#  所以切课必须用 click 模式。
# ============================================================

$Browser = 'msedge'
$DebugPort = 9222

# 夹具不需要登录态，用独立的临时配置目录，跑完可删
$ProfileDir = 'tests\fixture-profile'
$StartUrl = 'http://127.0.0.1:8899/studentstudy.html'

# 夹具 URL 无 chapterId，只能靠点击目录切课
$SwitchMode = 'click'

$LessonIds = ''
$MaxLessons = 10
$MaxReplayPerLesson = 1
$MaxWaitMinutesPerLesson = 3
$PlaybackRate = 1.0
$PollSeconds = 3

# 测试时不抢前台，避免影响你正在用的窗口
$KeepForeground = $false

$LogFile = 'logs\fixture.log'
