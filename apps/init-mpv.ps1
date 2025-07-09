<#
.SYNOPSIS
    Initialize mpv
.NOTES
    https://github.com/mpv-player/mpv
#>

if (-not (Get-Command "mpv" -ErrorAction SilentlyContinue)) {
    return
}

function global:view-video {
    param($path)
    & mpv --really-quiet --vo=tct $path
}