<#
    在你（用户）的真实课程页上验证新版适配：
      1. 识别平台版本
      2. 定位目录所在上下文
      3. 读出课节列表与完成状态
      4. 验证切课函数能否找到

    本脚本是只读验证：不切课、不播放。
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking
Set-CdpLogPath -Path (Join-Path $root 'logs\verify.log')
Remove-Item (Join-Path $root 'logs\verify.log') -Force -ErrorAction SilentlyContinue

$raw = Import-CourseSelectors
Write-Output ('选择器区块: ' + (($raw.Keys | Sort-Object) -join ', '))

# 找课程页标签页
$page = $null
foreach ($t in (Get-CdpTargets -Port 9222)) {
    if ($t.type -eq 'page' -and $t.url -match 'studentstudy') { $page = $t; break }
}
if (-not $page) { Write-Output '找不到 studentstudy 标签页'; exit 1 }
Write-Output ('课程页: ' + $page.url.Substring(0, [Math]::Min(120, $page.url.Length)))

$session = New-CdpSession -Page $page -Port 9222
try {
    Write-Output ''
    Write-Output '=== 1. 平台识别 ==='
    $plat = Resolve-Platform -Session $session -RawSelectors $raw
    Write-Output ('  版本        = ' + $plat.Version)
    Write-Output ('  legacy 节点  = ' + $plat.LegacyCount)
    Write-Output ('  mooc2 条目   = ' + $plat.Mooc2Count)
    Write-Output ('  目录上下文   = ' + $plat.DirContextId + $(if ($plat.DirContextId -eq 0) { ' (顶层)' } else { ' (iframe 内)' }))

    if ($plat.Version -eq '') { Write-Output '  版本识别失败'; exit 1 }

    $sel = $plat.Selectors
    Write-Output ('  合并后键数   = ' + $sel.Keys.Count)
    Write-Output ('  LessonNode  = ' + $sel.LessonNode)
    Write-Output ('  UnfinishedBy= ' + $sel.UnfinishedBy)

    Write-Output ''
    Write-Output '=== 2. 课节列表 ==='
    $lessons = @(Get-LessonList -Session $session -Selectors $sel -DirContextId $plat.DirContextId)
    Write-Output ('  读到课节数 = ' + $lessons.Count)
    if ($lessons.Count -eq 0) {
        Write-Output '  读不到课节 —— 需要继续排查'
        $log = Join-Path $root 'logs\verify.log'
        if (Test-Path $log) { Write-Output '  --- 诊断日志 ---'; Get-Content $log -Encoding UTF8 | Select-Object -Last 12 | ForEach-Object { '    ' + $_ } }
        exit 1
    }

    $unfin = @($lessons | Where-Object { $_.Unfinished })
    Write-Output ('  未完成     = ' + $unfin.Count)
    Write-Output ('  已完成     = ' + ($lessons.Count - $unfin.Count))

    Write-Output ''
    Write-Output '=== 3. 前 12 个课节 ==='
    $i = 0
    foreach ($l in ($lessons | Select-Object -First 12)) {
        $i++
        $t = $l.Title
        if ($t.Length -gt 40) { $t = $t.Substring(0, 40) + '…' }
        Write-Output ('  {0,2}. id={1} 未完成={2,-5} 计数={3,-3} active={4,-5} | {5}' -f $i, $l.Id, $l.Unfinished, $l.UnfinishedCount, $l.Active, $t)
    }

    Write-Output ''
    Write-Output '=== 4. 当前课节与 id ==='
    $cur = Get-CurrentLessonId -Session $session -Selectors $sel -DirContextId $plat.DirContextId
    $urlId = Get-UrlLessonId -Session $session
    $courseId = Get-CourseId -Session $session -Selectors $sel -DirContextId $plat.DirContextId
    $clazzId = Get-ClazzId -Session $session -Selectors $sel -DirContextId $plat.DirContextId
    Write-Output ('  Get-CurrentLessonId = ' + $cur)
    Write-Output ('  URL chapterId       = ' + $urlId)
    Write-Output ('  一致                = ' + ($cur -eq $urlId))
    Write-Output ('  courseId            = ' + $courseId)
    Write-Output ('  clazzId             = ' + $clazzId)

    Write-Output ''
    Write-Output '=== 5. 视频帧是否可达 ==='
    $vctx = Get-VideoContext -Session $session -Selectors $sel
    $cctx = Get-CardsContext -Session $session -Selectors $sel
    Write-Output ('  Get-CardsContext = ' + $cctx)
    Write-Output ('  Get-VideoContext = ' + $vctx)
    if ($vctx -gt 0) {
        $st = Get-VideoState -Session $session -ContextId $vctx
        Write-Output ('  播放器状态: Ok=' + $st.Ok + ' 位置=' + [math]::Round($st.Current, 1) + ' 时长=' + [math]::Round($st.Duration, 1) + ' 暂停=' + $st.Paused)
    }
    if ($cctx -gt 0) {
        $fin = Test-JobFinished -Session $session -Selectors $sel -ContextId $cctx
        Write-Output ('  任务点已完成标记 = ' + $fin)
    }
} finally {
    Close-CdpSession -Session $session
}
