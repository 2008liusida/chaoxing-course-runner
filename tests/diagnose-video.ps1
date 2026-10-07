<#
    深挖：为什么 play() 成功但进度不走。
    读 video 元素的完整状态：readyState / networkState / error / src / buffered。
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking
Set-CdpLogPath -Path (Join-Path $root 'logs\video.log')
$raw = Import-CourseSelectors

$page = $null
foreach ($t in (Get-CdpTargets -Port 9222)) { if ($t.type -eq 'page' -and $t.url -match 'studentstudy') { $page = $t; break } }
if (-not $page) { Write-Output '找不到课程页'; exit 1 }
$s = New-CdpSession -Page $page -Port 9222
try {
    $plat = Resolve-Platform -Session $s -RawSelectors $raw
    $sel = $plat.Selectors
    Write-Output ('版本: ' + $plat.Version + '  当前课节: ' + (Get-CurrentLessonId -Session $s -Selectors $sel -DirContextId $plat.Dir))

    $vctx = Get-VideoContext -Session $s -Selectors $sel
    Write-Output ('播放器上下文: ' + $vctx)
    if ($vctx -le 0) { Write-Output '读不到播放器'; exit 1 }

    Write-Output ''
    Write-Output '=== video 元素完整状态 ==='
    $js = 'JSON.stringify((function(){var v=document.querySelector("video");if(!v)return{has:false};return{has:true,currentTime:v.currentTime,duration:v.duration,paused:v.paused,readyState:v.readyState,networkState:v.networkState,error:v.error?v.error.code:null,errorMsg:v.error?v.error.message:null,src:(v.src||"").slice(0,150),currentSrc:(v.currentSrc||"").slice(0,150),playbackRate:v.playbackRate,volume:v.volume,muted:v.muted,autoplay:v.autoplay,preload:v.preload,bufferedRanges:v.buffered?v.buffered.length:0,bufferedEnd:(v.buffered&&v.buffered.length)?v.buffered.end(0):-1,seekable:(v.seekable?v.seekable.length:0),videoWidth:v.videoWidth,videoHeight:v.videoHeight};})())'
    Write-Output ($s | ForEach-Object { (Invoke-CdpJs -Session $_ -Expression $js -ContextId $vctx).Value })

    Write-Output ''
    Write-Output '=== 播放器外层是否有遮罩 / 提示（影响能否播放）==='
    $ov = 'JSON.stringify((function(){var o=[];document.querySelectorAll("div,span,p").forEach(function(e){var t=(e.innerText||"").replace(/\s+/g," ").trim();if(t&&t.length<50&&/点击|开始|播放|继续|拖动|验证|禁止|提示|尚未/.test(t)){var st=getComputedStyle(e);if(st.display!=="none"&&st.visibility!=="hidden"){o.push(e.tagName+"."+(e.className||"").slice(0,40)+" ["+t+"]")}}});return o.slice(0,10);})())'
    Write-Output (Invoke-CdpJs -Session $s -Expression $ov -ContextId $vctx).Value

    Write-Output ''
    Write-Output '=== 尝试用点击播放按钮（而不是直接 play()）==='
    $btn = 'JSON.stringify((function(){var o=[];document.querySelectorAll("button,div[role=button],.vjs-big-play-button,.vjs-play-control").forEach(function(e){var st=getComputedStyle(e);if(st.display!=="none"){o.push(e.tagName+"."+(e.className||"").slice(0,50)+" aria="+(e.getAttribute("aria-label")||""))}});return o.slice(0,10);})())'
    Write-Output (Invoke-CdpJs -Session $s -Expression $btn -ContextId $vctx).Value

    Write-Output ''
    Write-Output '=== 点击大播放按钮后观察 ==='
    $click = 'JSON.stringify((function(){var b=document.querySelector(".vjs-big-play-button")||document.querySelector(".vjs-play-control");if(!b)return{clicked:false};b.click();return{clicked:true,cls:b.className};})())'
    Write-Output (Invoke-CdpJs -Session $s -Expression $click -ContextId $vctx).Value
    Start-Sleep -Seconds 8
    $st2 = 'JSON.stringify((function(){var v=document.querySelector("video");return{currentTime:v.currentTime,duration:v.duration,paused:v.paused,readyState:v.readyState,networkState:v.networkState,error:v.error?v.error.code:null};})())'
    Write-Output ('  点击后: ' + (Invoke-CdpJs -Session $s -Expression $st2 -ContextId $vctx).Value)
    Start-Sleep -Seconds 12
    Write-Output ('  再等 12 秒: ' + (Invoke-CdpJs -Session $s -Expression $st2 -ContextId $vctx).Value)

    Write-Output ''
    Write-Output '=== 页面/帧可见性（不可见会影响播放与计时）==='
    Write-Output ('  document.visibilityState = ' + (Invoke-CdpJs -Session $s -Expression 'document.visibilityState').Value)
    Write-Output ('  document.hidden         = ' + (Invoke-CdpJs -Session $s -Expression 'String(document.hidden)').Value)
    Write-Output ('  播放器帧 visibilityState = ' + (Invoke-CdpJs -Session $s -Expression 'document.visibilityState' -ContextId $vctx).Value)
} finally {
    Close-CdpSession -Session $s
}
