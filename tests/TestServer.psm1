<#
.SYNOPSIS
    启动一个极简的本地静态文件服务，供离线自测使用。

.DESCRIPTION
    用 .NET HttpListener 实现，不依赖 Python / Node。
    支持子目录，并按扩展名返回正确的 Content-Type ——
    夹具需要复刻学习通的 iframe 路径（knowledge/cards.html、
    ananas/modules/video/index.html），所以必须支持子目录。

.PARAMETER Directory
    要对外提供的目录。
.PARAMETER Port
    监听端口。

.EXAMPLE
    $job = Start-TestServer -Directory .\tests\fixture -Port 8899
    # 结束时：Stop-Job $job; Remove-Job $job
#>

Set-StrictMode -Version Latest

function Start-TestServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Directory,
        [int]$Port = 8899
    )

    $root = (Resolve-Path $Directory).Path

    $scriptBlock = {
        param($rootPath, $listenPort)

        $mime = @{
            '.html' = 'text/html; charset=utf-8'
            '.htm'  = 'text/html; charset=utf-8'
            '.js'   = 'application/javascript; charset=utf-8'
            '.css'  = 'text/css; charset=utf-8'
            '.json' = 'application/json; charset=utf-8'
            '.png'  = 'image/png'
            '.jpg'  = 'image/jpeg'
            '.svg'  = 'image/svg+xml'
            '.webm' = 'video/webm'
            '.mp4'  = 'video/mp4'
        }

        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$listenPort/")
        $listener.Start()

        try {
            while ($listener.IsListening) {
                $ctx = $null
                try { $ctx = $listener.GetContext() } catch { break }
                if ($null -eq $ctx) { break }

                try {
                    $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
                    if (-not $rel) { $rel = 'studentstudy.html' }

                    # 防目录穿越：解析后必须仍在根目录内
                    $full = [System.IO.Path]::GetFullPath((Join-Path $rootPath $rel))
                    if (-not $full.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
                        $ctx.Response.StatusCode = 403
                        $ctx.Response.Close()
                        continue
                    }

                    if (Test-Path $full -PathType Leaf) {
                        $bytes = [System.IO.File]::ReadAllBytes($full)
                        $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
                        $ctx.Response.ContentType = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
                        $ctx.Response.ContentLength64 = $bytes.Length
                        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    } else {
                        $ctx.Response.StatusCode = 404
                        $msg = [System.Text.Encoding]::UTF8.GetBytes("404 $rel")
                        $ctx.Response.OutputStream.Write($msg, 0, $msg.Length)
                    }
                } catch {
                    try { $ctx.Response.StatusCode = 500 } catch { }
                } finally {
                    try { $ctx.Response.Close() } catch { }
                }
            }
        } finally {
            try { $listener.Stop(); $listener.Close() } catch { }
        }
    }

    return Start-Job -ScriptBlock $scriptBlock -ArgumentList $root, $Port
}

function Wait-TestServer {
    <#
    .SYNOPSIS
        等待本地服务可用。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSeconds = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            Invoke-WebRequest -Uri $Url -TimeoutSec 2 -UseBasicParsing | Out-Null
            return $true
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }
    return $false
}
