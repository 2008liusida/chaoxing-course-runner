<#
    冒烟验证（修正版）：真的切到下一节、真的开始播放，然后立即恢复现场。
    只播约 20 秒用于确认链路。

    关键点：切课若走 "navigate"（整页导航），旧 CDP 会话会失效，
    必须重新建立会话再读写。初版脚本漏了这一步，造成了假失败。
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking
Set-CdpLogPath -Path (Join-Path $root 'logs\smoke.log')

$raw = Import-CourseSelectors

function Get-Context {
    <#  重新定位课程页、建会话、识别版本；切课/导航后必须重新调用  #>
    $page = $null
    foreach ($t in (Get-CdpTargets -Port 9222)) {
        if ($t.type -eq 'page' -and $t.url -match 'studentstudy') { $page = $t; break }
    }
    if (-not $page) { return $null }
    $s = New-CdpSession -Page $page -Port 9222
    $plat = Resolve-Platform -Session $s -RawSelectors $raw
    return @{ Session = $s; Selectors = $plat.Selectors; Dir = $plat.DirContextId; Version = $plat.Version }
}

$ctx = Get-Context
if (-not $ctx) { Write-Output '找不到课程页'; exit 1 }
Write-Output ('平台版本: ' + $ctx.Version)

$origId = Get-CurrentLessonId -Session $ctx.Session -Selectors $ctx.Selectors -DirContextId $ctx.Dir
Write-Output ('原始课节: ' + $origId)

$lessons = @(Get-LessonList -Session $ctx.Session -Selectors $ctx.Selectors -DirContextId $ctx.Dir)
$unfin = @($lessons | Where-Object { $_.Unfinished })
$target = $null
foreach ($l in $unfin) { if ($l.Id -ne $origId) { $target = $l; break } }
if (-not $target) { Write-Output '找不到可测试的目标课节'; Close-CdpSession $ctx.Session; exit 1 }
Write-Output ('目标课节: ' + $target.Id + '  ' + $target.Title)

# ---------------- 1. 切课 ----------------
Write-Output ''
Write-Output '=== 1. 切课 ==='
$how = Switch-Lesson -Session $ctx.Session -Selectors $ctx.Selectors -LessonId $target.Id -DirContextId $ctx.Dir
Write-Output ('  切课方式: ' + $how)

Close-CdpSession $ctx.Session
Start-Sleep -Seconds 10
$ctx = Get-Context
$ok = ((Get-CurrentLessonId -Session $ctx.Session -Selectors $ctx.Selectors -DirContextId $ctx.Dir) -eq $target.Id)
if (-not $ok) {
    Start-Sleep -Seconds 10
    $ctx = Get-Context
    $ok = ((Get-CurrentLessonId -Session $ctx.Session -Selectors $ctx.Selectors -DirContextId $ctx.Dir) -eq $target.Id)
}
Write-Output ('  切课成功: ' + $ok)
if (-not $ok) { Write-Output '  切课失败，停止'; Close-CdpSession $ctx.Session; exit 1 }

# ---------------- 2. 播放 ----------------
Write-Output ''
Write-Output '=== 2. 播放 ==='
$vctx = Get-VideoContext -Session $ctx.Session -Selectors $ctx.Selectors
Write-Output ('  播放器上下文: ' + $vctx)
if ($vctx -le 0) { Write-Output '  读不到播放器，停止'; Close-CdpSession $ctx.Session; exit 1 }

$st = Get-VideoState -Session $ctx.Session -ContextId $vctx
Write-Output ('  初始: 时长=' + [math]::Round($st.Duration, 1) + ' 暂停=' + $st.Paused)

if ($st.Duration -le 0) {
    $r = Start-VideoPlayback -Session $ctx.Session -ContextId $vctx -Rate 1.0
    Write-Output ('  时长未就绪，调 play(): ' + $r)
    Start-Sleep -Seconds 12
    $vctx = Get-VideoContext -Session $ctx.Session -Selectors $ctx.Selectors
    $st = Get-VideoState -Session $ctx.Session -ContextId $vctx
    Write-Output ('  加载后: 时长=' + [math]::Round($st.Duration, 1) + ' 暂停=' + $st.Paused + ' (ctx=' + $vctx + ')')
}
if ($st.Paused) {
    $r = Start-VideoPlayback -Session $ctx.Session -ContextId $vctx -Rate 1.0
    Write-Output ('  继续播放: ' + $r)
}

# ---------------- 3. 观察进度 ----------------
Write-Output ''
Write-Output '=== 3. 观察 20 秒，确认进度在走 ==='
$a = Get-VideoState -Session $ctx.Session -ContextId $vctx
Write-Output ('  t0 : ' + [math]::Round($a.Current, 1) + ' 秒')
Start-Sleep -Seconds 20
$b = Get-VideoState -Session $ctx.Session -ContextId $vctx
Write-Output ('  t20: ' + [math]::Round($b.Current, 1) + ' 秒')
$delta = $b.Current - $a.Current
$verdict = if ($delta -gt 10) { '播放正常' } else { '播放异常，需排查' }
Write-Output ('  前进 ' + [math]::Round($delta, 1) + ' 秒 -> ' + $verdict)

# ---------------- 4. 恢复现场 ----------------
Write-Output ''
Write-Output '=== 4. 暂停并切回原课节 ==='
$pv = Invoke-CdpJs -Session $ctx.Session -ContextId $vctx -Expression 'var v=document.querySelector("video"); if(v){v.pause();} "paused"'
Write-Output ('  暂停: ' + $pv.Value)

[void](Switch-Lesson -Session $ctx.Session -Selectors $ctx.Selectors -LessonId $origId -DirContextId $ctx.Dir)
Close-CdpSession $ctx.Session
Start-Sleep -Seconds 10
$ctx = Get-Context
$backId = Get-CurrentLessonId -Session $ctx.Session -Selectors $ctx.Selectors -DirContextId $ctx.Dir
Write-Output ('  已回到: ' + $backId + '  (期望 ' + $origId + ')  成功=' + ($backId -eq $origId))
Close-CdpSession $ctx.Session
