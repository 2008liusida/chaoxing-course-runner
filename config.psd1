# ============================================================
#  ChaoxingCourseRunner 配置
#
#  这是唯一需要使用者修改的文件。改完保存，下次运行生效。
#  键名与 lib\Settings.psm1 里的 $defaults 一一对应；
#  写错的键会被忽略（不会导致启动失败）。
# ============================================================

# 浏览器：'msedge' 或 'chrome'。
# 留空则自动探测：先 Edge，再 Chrome，再 Brave。
$Browser = 'msedge'

# 调试端口。若被占用（例如你已开着另一个调试实例），改成一个 9222-9299 的数字。
$DebugPort = 9222

# 浏览器用户配置目录（保存登录态）。
#   留空 = 使用工具目录下的 browser-profile\   ← 推荐
#
# 这个目录是"独立"的：工具会新开一个浏览器窗口，与你日常用的
# Edge/Chrome 完全隔离，不会动你现有的标签页和登录状态。
# 代价是：学习通需要在这个新窗口里登录一次（之后长期有效）。
#
# 不要指向你日常在用的 Edge/Chrome 配置目录 —— 两者会互相干扰，
# 而且日常浏览器已经在运行时，调试端口往往起不来。
$ProfileDir = ''

# 浏览器启动时打开的页面。
# 保持为学习通登录页：新窗口打开即可直接登录。
# 若你更希望它打开课程列表，可改为 https://i.mooc.chaoxing.com/space/index
$StartUrl = 'https://passport2.chaoxing.com/login'

# 切课方式：
#   auto  = 优先直接改写地址栏里的 chapterId（最稳，不依赖页面脚本）；
#   click = 只用点击目录链接 / 调用页面函数。
# 正常保持 auto。只有课程页 URL 不含 chapterId 时才需要改成 click。
$SwitchMode = 'auto'

# 只处理指定课节 id，多个用逗号分隔；留空 = 自动处理目录里所有"未完成"课节。
# 先用 -DryRun 跑一次，日志里会列出每个待处理课节的 id。
$LessonIds = ''

# 本次最多处理几节（安全阀，防止意外跑太久）。
$MaxLessons = 50

# 单节播完后若平台未登记完成，允许从头重播几次。
# 有些课节要求 100% 观看时长，正常 1 次足够。
$MaxReplayPerLesson = 1

# 单节最长等待分钟数，超过则跳过该节并记录。
$MaxWaitMinutesPerLesson = 40

# 播放速率。平台会检测倍速，非 1 倍可能不计入时长，强烈建议保持 1.0。
$PlaybackRate = 1.0

# 进度轮询间隔（秒）。
$PollSeconds = 1

# 是否持续把浏览器窗口置于前台。
# 超星的完成条件写明"观看时不可离开或将页面最小化"，
# 保持前台最稳妥。若你需要在跑的同时使用电脑，可在命令行用 -NoForeground 关闭。
$KeepForeground = $true

# 日志文件路径（相对工具目录或绝对路径）。
$LogFile = 'logs\run.log'
