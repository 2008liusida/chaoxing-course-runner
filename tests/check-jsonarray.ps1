<#
    只验证 ConvertFrom-JsonArray：喂原始 JSON，看返回条数。
    与浏览器、夹具都无关，纯函数级测试。
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'lib\ChaoxingCourseRunner.psd1') -Force -DisableNameChecking

Write-Output ('PSVersion = ' + $PSVersionTable.PSVersion.ToString())

$json = '[{"Id":"1","Title":"a","Unfinished":true},{"Id":"2","Title":"b","Unfinished":false},{"Id":"3","Title":"c","Unfinished":true}]'
Write-Output ('输入 JSON 长度 = ' + $json.Length)

$r = ConvertFrom-JsonArray -Json $json
Write-Output ('返回类型 = ' + $r.GetType().FullName)
Write-Output ('返回条数 = ' + @($r).Count)
foreach ($item in @($r)) {
    Write-Output ('  Id=' + $item.Id + '  Unfinished=' + $item.Unfinished)
}

Write-Output ''
Write-Output '--- 对照：原生 ConvertFrom-Json ---'
$native = ConvertFrom-Json -InputObject $json
Write-Output ('原生类型 = ' + $native.GetType().FullName)
Write-Output ('原生 @() 条数 = ' + @($native).Count)
Write-Output ('原生是否 IEnumerable = ' + ($native -is [System.Collections.IEnumerable]))

Write-Output ''
Write-Output '--- 空值/异常路径 ---'
Write-Output ('空字符串 -> ' + @(ConvertFrom-JsonArray -Json '').Count)
Write-Output ('null     -> ' + @(ConvertFrom-JsonArray -Json $null).Count)
Write-Output ('非数组   -> ' + @(ConvertFrom-JsonArray -Json '{"a":1}').Count)
