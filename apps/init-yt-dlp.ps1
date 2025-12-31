<#!
.SYNOPSIS
    Initialize yt-dlp helper functions
.NOTES
    https://github.com/yt-dlp/yt-dlp
#>

if (-not (Get-Command "yt-dlp" -ErrorAction SilentlyContinue)) {
    return
}

Set-Alias -Name ytdlp -Value yt-dlp -Scope Global

function global:yt-audio {
    <#
    .SYNOPSIS
        Download audio only (e.g. to mp3) from a URL.
    .PARAMETER Url
        Video or playlist URL.
    .PARAMETER Output
        Output template, default: "%(title)s.%(ext)s".
    .PARAMETER Format
        Audio format, default: "mp3".
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [string]$Output = "%(title)s.%(ext)s",
        [string]$Format = "mp3"
    )

    yt-dlp `
        --no-color `
        --ignore-config `
        --extract-audio `
        --audio-format $Format `
        --audio-quality 0 `
        --add-metadata `
        --embed-thumbnail `
        -o $Output `
        $Url
}

function global:yt-video {
    <#
    .SYNOPSIS
        Download best video+audio from a URL.
    .PARAMETER Url
        Video or playlist URL.
    .PARAMETER Output
        Output template, default: "%(title)s.%(ext)s".
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [string]$Output = "%(title)s.%(ext)s"
    )

    yt-dlp `
        --no-color `
        --ignore-config `
        -f "bv*+ba/b" `
        --merge-output-format mp4 `
        --add-metadata `
        --embed-chapters `
        --embed-thumbnail `
        -o $Output `
        $Url
}

function global:yt-list {
    <#
    .SYNOPSIS
        List formats for a given URL.
    .PARAMETER Url
        Video URL.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url
    )

    yt-dlp --no-color --ignore-config -F $Url
}

function global:yt-sub {
    <#
    .SYNOPSIS
        Download subtitles (and optionally video).
    .PARAMETER Url
        Video URL.
    .PARAMETER Lang
        Subtitle language (default: "en").
    .PARAMETER WithVideo
        Also download video when specified.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [string]$Lang = "en",
        [switch]$WithVideo
    )

    $argsCommon = @(
        "--no-color",
        "--ignore-config",
        "--write-sub",
        "--write-auto-sub",
        "--sub-langs", $Lang,
        "--sub-format", "best"
    )

    if ($WithVideo) {
        yt-dlp @argsCommon -f "bv*+ba/b" --merge-output-format mp4 $Url
    }
    else {
        yt-dlp @argsCommon --skip-download $Url
    }
}
