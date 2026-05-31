<#
.SYNOPSIS
    Initialize ffmpeg helper functions
.NOTES
    https://ffmpeg.org
#>

if (-not (Get-Command "ffmpeg" -ErrorAction SilentlyContinue)) {
    return
}

function global:ff-convert {
    <#
    .SYNOPSIS
        Convert a video file to a different format.
    .PARAMETER InputFile
        Source video file path.
    .PARAMETER OutputFile
        Output file path. Extension determines the target format.
    .PARAMETER Overwrite
        Overwrite output file if it already exists.
    .EXAMPLE
        ff-convert input.avi output.mp4
        ff-convert input.mkv output.mp4 -Overwrite
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$InputFile,
        [Parameter(Mandatory, Position = 1)]
        [string]$OutputFile,
        [switch]$Overwrite
    )

    if (-not (Test-Path -LiteralPath $InputFile)) {
        Write-Error "Input file not found: $InputFile"
        return
    }

    $overwriteFlag = if ($Overwrite) { "-y" } else { "-n" }

    ffmpeg $overwriteFlag -i $InputFile -c copy $OutputFile
}

function global:ff-trim {
    <#
    .SYNOPSIS
        Fast-trim (keep) a video segment without re-encoding.
    .PARAMETER InputFile
        Source video file path.
    .PARAMETER Start
        Start time of the segment to keep. Accepts HH:MM:SS, MM:SS, or seconds.
    .PARAMETER End
        End time of the segment to keep. Accepts HH:MM:SS, MM:SS, or seconds.
        If omitted, trims to end of file.
    .PARAMETER OutputFile
        Output file path. Defaults to "<input>_trim.<ext>".
    .PARAMETER Overwrite
        Overwrite output file if it already exists.
    .EXAMPLE
        ff-trim input.mp4 -Start 00:01:00 -End 00:02:30
        ff-trim input.mp4 -Start 30 -End 90 -OutputFile clip.mp4 -Overwrite
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$InputFile,
        [Parameter(Mandatory)]
        [string]$Start,
        [string]$End,
        [string]$OutputFile,
        [switch]$Overwrite
    )

    if (-not (Test-Path -LiteralPath $InputFile)) {
        Write-Error "Input file not found: $InputFile"
        return
    }

    if (-not $OutputFile) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
        $ext  = [System.IO.Path]::GetExtension($InputFile)
        $dir  = [System.IO.Path]::GetDirectoryName($InputFile)
        $OutputFile = Join-Path $dir "${base}_trim${ext}"
    }

    $overwriteFlag = if ($Overwrite) { "-y" } else { "-n" }
    $endArgs = if ($End) { @("-to", $End) } else { @() }

    ffmpeg $overwriteFlag -ss $Start @endArgs -i $InputFile -c copy $OutputFile
}

function global:ff-cut {
    <#
    .SYNOPSIS
        Fast-cut (remove) a video segment, keeping everything outside the range.
        Produces two clips: the part before Start and the part after End.
    .PARAMETER InputFile
        Source video file path.
    .PARAMETER Start
        Start time of the segment to remove. Accepts HH:MM:SS, MM:SS, or seconds.
    .PARAMETER End
        End time of the segment to remove. Accepts HH:MM:SS, MM:SS, or seconds.
    .PARAMETER OutputDir
        Directory for the output files. Defaults to the same directory as InputFile.
    .PARAMETER Overwrite
        Overwrite output files if they already exist.
    .EXAMPLE
        ff-cut input.mp4 -Start 00:01:00 -End 00:02:30
        ff-cut input.mp4 -Start 60 -End 150 -Overwrite
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$InputFile,
        [Parameter(Mandatory)]
        [string]$Start,
        [Parameter(Mandatory)]
        [string]$End,
        [string]$OutputDir,
        [switch]$Overwrite
    )

    if (-not (Test-Path -LiteralPath $InputFile)) {
        Write-Error "Input file not found: $InputFile"
        return
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
    $ext  = [System.IO.Path]::GetExtension($InputFile)
    $dir  = if ($OutputDir) { $OutputDir } else { [System.IO.Path]::GetDirectoryName($InputFile) }

    $part1 = Join-Path $dir "${base}_cut_part1${ext}"
    $part2 = Join-Path $dir "${base}_cut_part2${ext}"

    $overwriteFlag = if ($Overwrite) { "-y" } else { "-n" }

    Write-Host "Extracting part before $Start -> $part1"
    ffmpeg $overwriteFlag -i $InputFile -to $Start -c copy $part1

    Write-Host "Extracting part after $End -> $part2"
    ffmpeg $overwriteFlag -ss $End -i $InputFile -c copy $part2
}

function global:ff-extract-audio {
    <#
    .SYNOPSIS
        Extract audio track from a video file.
    .PARAMETER InputFile
        Source video file path.
    .PARAMETER OutputFile
        Output audio file path. Defaults to "<input>.<ext>" with detected audio extension.
    .PARAMETER Format
        Audio format/container, e.g. mp3, aac, flac, wav. Default: mp3.
    .PARAMETER Overwrite
        Overwrite output file if it already exists.
    .EXAMPLE
        ff-extract-audio input.mp4
        ff-extract-audio input.mkv -Format flac -Overwrite
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$InputFile,
        [string]$OutputFile,
        [string]$Format = "mp3",
        [switch]$Overwrite
    )

    if (-not (Test-Path -LiteralPath $InputFile)) {
        Write-Error "Input file not found: $InputFile"
        return
    }

    if (-not $OutputFile) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
        $dir  = [System.IO.Path]::GetDirectoryName($InputFile)
        $OutputFile = Join-Path $dir "${base}.${Format}"
    }

    $overwriteFlag = if ($Overwrite) { "-y" } else { "-n" }

    ffmpeg $overwriteFlag -i $InputFile -vn $OutputFile
}

function global:ff-screenshot {
    <#
    .SYNOPSIS
        Take a screenshot from a video at a given timestamp.
    .PARAMETER InputFile
        Source video file path.
    .PARAMETER Time
        Timestamp for the screenshot. Accepts HH:MM:SS, MM:SS, or seconds.
    .PARAMETER OutputFile
        Output image file path. Defaults to "<input>_<time>.jpg".
    .PARAMETER Overwrite
        Overwrite output file if it already exists.
    .EXAMPLE
        ff-screenshot input.mp4 -Time 00:01:30
        ff-screenshot input.mp4 -Time 90 -OutputFile thumb.png -Overwrite
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$InputFile,
        [Parameter(Mandatory)]
        [string]$Time,
        [string]$OutputFile,
        [switch]$Overwrite
    )

    if (-not (Test-Path -LiteralPath $InputFile)) {
        Write-Error "Input file not found: $InputFile"
        return
    }

    if (-not $OutputFile) {
        $base    = [System.IO.Path]::GetFileNameWithoutExtension($InputFile)
        $dir     = [System.IO.Path]::GetDirectoryName($InputFile)
        $safeTime = $Time -replace ":", "-"
        $OutputFile  = Join-Path $dir "${base}_${safeTime}.jpg"
    }

    $overwriteFlag = if ($Overwrite) { "-y" } else { "-n" }

    ffmpeg $overwriteFlag -ss $Time -i $InputFile -frames:v 1 $OutputFile
}
