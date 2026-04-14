<#
.SYNOPSIS
    Serves a file or directory via a simple HTTP server.
.PARAMETER file
    HTML file to serve directly (opens browser automatically).
.PARAMETER directory
    Directory to serve files from.
.PARAMETER port
    Port number (default: 8000).
.PARAMETER bind
    Bind address (default: 127.0.0.1).
.EXAMPLE
    PS> ./simple-server.ps1 -file "index.html"
.EXAMPLE
    PS> ./simple-server.ps1 -directory "C:\web" -port 9000
#>

param(
    [Alias("f")][string]$file,
    [Alias("d")][string]$directory,
    [Alias("p")][int]$port = 8000,
    [Alias("b")][string]$bind = "127.0.0.1"
)

if ($file -and $directory) {
    Write-Error "Specify either -file or -directory, not both."
    exit 1
}

$serveDir = $PWD.Path
$openUrl  = $null

if ($file) {
    $absFile = Resolve-Path $file -ErrorAction SilentlyContinue
    if (-not $absFile) { $absFile = Join-Path $PWD.Path $file }
    if (-not (Test-Path $absFile)) { Write-Error "File not found: $file"; exit 1 }
    $serveDir = Split-Path $absFile -Parent
    $fileName = Split-Path $absFile -Leaf
    $openUrl  = "http://${bind}:${port}/$fileName"
} elseif ($directory) {
    $absDir = Resolve-Path $directory -ErrorAction SilentlyContinue
    if (-not $absDir) { $absDir = Join-Path $PWD.Path $directory }
    if (-not (Test-Path $absDir)) { Write-Error "Directory not found: $directory"; exit 1 }
    $serveDir = $absDir
}

$prefix   = "http://${bind}:${port}/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Host "Serving at $prefix" -ForegroundColor Cyan
Write-Host "Directory: $serveDir"
Write-Host "Press Ctrl+C to stop"

if ($openUrl) {
    Start-Job { param($u) Start-Sleep -Milliseconds 500; Start-Process $u } -ArgumentList $openUrl | Out-Null
}

$mimeMap = @{
    '.html' = 'text/html'
    '.htm'  = 'text/html'
    '.css'  = 'text/css'
    '.js'   = 'application/javascript'
    '.json' = 'application/json'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        $res = $ctx.Response

        $urlPath  = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
        $filePath = if ($urlPath) { Join-Path $serveDir $urlPath } else { $serveDir }

        if (Test-Path $filePath -PathType Leaf) {
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            $ext   = [System.IO.Path]::GetExtension($filePath).ToLower()
            $res.ContentType     = $( if ($mimeMap.ContainsKey($ext)) { $mimeMap[$ext] } else { 'application/octet-stream' } )
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } elseif (Test-Path $filePath -PathType Container) {
            $items = Get-ChildItem $filePath | ForEach-Object {
                $suffix = if ($_.PSIsContainer) { '/' } else { '' }
                $displayName = $_.Name + $suffix
                $encodedName = [System.Uri]::EscapeDataString($_.Name) + $suffix
                "<li><a href='$encodedName'>$([System.Net.WebUtility]::HtmlEncode($displayName))</a></li>"
            }
            $html  = "<html><body><ul>$($items -join '')</ul></body></html>"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
            $res.ContentType     = 'text/html; charset=utf-8'
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
            $res.StatusCode      = 404
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found")
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
        }
        $res.OutputStream.Close()
    }
} finally {
    $listener.Stop()
}
