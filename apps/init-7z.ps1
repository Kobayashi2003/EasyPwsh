<#
.SYNOPSIS
    Initialize 7-Zip helper functions
.NOTES
    https://www.7-zip.org
#>

if (-not (Get-Command "7z" -ErrorAction SilentlyContinue)) {
    return
}

function global:7z-extract {
    <#
    .SYNOPSIS
        Extract archives with 7-Zip, with support for passwords, multi-volume
        sets, recursive scanning, post-extraction deletion, and configurable
        output layout.
    .PARAMETER Path
        Archive file, or a directory to scan for archives.
    .PARAMETER Password
        Password for encrypted archives.
    .PARAMETER OutputDir
        Base directory for extraction. Defaults to each archive's own directory.
    .PARAMETER Mode
        Output layout:
          Folder - extract into a new folder named after the archive (default).
          Flat   - extract directly into the target directory (no new folder).

        Combined with OutputDir this covers the common cases:
          Mode Folder (no OutputDir) -> new folder beside the archive.
          Mode Folder + OutputDir    -> new folder under the specified directory.
          Mode Flat   (no OutputDir) -> extract straight into the archive's dir.
    .PARAMETER Recurse
        When Path is a directory, scan it recursively for archives.
    .PARAMETER DeleteAfter
        Delete the archive (all volumes) after a successful extraction.
    .PARAMETER Overwrite
        Overwrite existing files. By default existing files are skipped.
    .EXAMPLE
        7z-extract archive.7z
        7z-extract secret.zip -Password hunter2
        7z-extract data.7z.001 -DeleteAfter
        7z-extract .\downloads -Recurse -Mode Folder -DeleteAfter
        7z-extract archive.rar -OutputDir D:\out -Mode Flat -Overwrite
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,
        [string]$Password,
        [string]$OutputDir,
        [ValidateSet("Folder", "Flat")]
        [string]$Mode = "Folder",
        [switch]$Recurse,
        [switch]$DeleteAfter,
        [switch]$Overwrite
    )

    # Archive extensions recognized when scanning a directory.
    $archiveExtensions = @(
        ".7z", ".zip", ".rar", ".tar", ".gz", ".bz2", ".xz", ".zst",
        ".tgz", ".tbz", ".txz", ".tzst", ".lzma", ".lz4", ".cab",
        ".iso", ".wim", ".cpio", ".arj", ".lzh", ".z"
    )

    # Returns $true if the file is a standalone archive or the FIRST volume
    # of a multi-volume set (so the set is extracted exactly once).
    function Test-FirstVolume([System.IO.FileInfo]$File) {
        $name = $File.Name
        # .001 / .002 ... style (e.g. archive.7z.001, archive.zip.001)
        if ($name -match '\.\d{3,}$') { return ($name -match '\.0*1$') }
        # .partN.rar style (e.g. archive.part1.rar, archive.part01.rar)
        if ($name -match '\.part(\d+)\.rar$') { return ([int]$Matches[1] -eq 1) }
        # legacy split rar: first volume is .rar, the rest are .r00, .r01 ...
        if ($name -match '\.r\d{2}$') { return $false }
        # zip split companions: .z01, .z02 ... (first volume is .zip)
        if ($name -match '\.z\d{2}$') { return $false }
        return $true
    }

    # Folder name to extract into, derived from the archive file name.
    function Get-ArchiveBaseName([System.IO.FileInfo]$File) {
        $name = $File.Name
        $name = $name -replace '\.\d{3,}$', ''        # strip .001
        $name = $name -replace '\.part\d+\.rar$', ''  # strip .partN.rar
        $name = [System.IO.Path]::GetFileNameWithoutExtension($name)
        if ($name -match '\.tar$') { $name = $name -replace '\.tar$', '' }  # .tar.gz etc.
        return $name
    }

    # All files belonging to the (possibly multi-volume) archive set.
    function Get-ArchiveVolumes([System.IO.FileInfo]$File) {
        $name = $File.Name
        $dir = $File.DirectoryName

        if ($name -match '^(.*)\.\d{3,}$') {
            $stem = [regex]::Escape($Matches[1])
            return Get-ChildItem -LiteralPath $dir -File |
                Where-Object { $_.Name -match ('^' + $stem + '\.\d{3,}$') } |
                Select-Object -ExpandProperty FullName
        }
        if ($name -match '^(.*)\.part\d+\.rar$') {
            $stem = [regex]::Escape($Matches[1])
            return Get-ChildItem -LiteralPath $dir -File |
                Where-Object { $_.Name -match ('^' + $stem + '\.part\d+\.rar$') } |
                Select-Object -ExpandProperty FullName
        }
        return @($File.FullName)
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "Path not found: $Path"
        return
    }

    # Resolve the set of archives to process.
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $files = Get-ChildItem -LiteralPath $Path -File -Recurse:$Recurse |
            Where-Object {
                ($archiveExtensions -contains $_.Extension.ToLower()) -or
                ($_.Name -match '\.\d{3,}$') -or
                ($_.Name -match '\.part\d+\.rar$')
            } |
            Where-Object { Test-FirstVolume $_ }

        if (-not $files) {
            Write-Warning "No archives found in: $Path"
            return
        }
    }
    else {
        $files = @(Get-Item -LiteralPath $Path)
    }

    $overwriteSwitch = if ($Overwrite) { "-aoa" } else { "-aos" }

    foreach ($file in $files) {
        $baseDir = if ($OutputDir) { $OutputDir } else { $file.DirectoryName }
        $target = if ($Mode -eq "Folder") {
            Join-Path $baseDir (Get-ArchiveBaseName $file)
        }
        else {
            $baseDir
        }

        $arguments = @("x", $file.FullName, "-o$target", $overwriteSwitch, "-y")
        if ($Password) { $arguments += "-p$Password" }

        Write-Host "Extracting $($file.Name) -> $target"
        7z @arguments

        if ($LASTEXITCODE -ne 0) {
            Write-Error "Extraction failed ($LASTEXITCODE): $($file.Name)"
            continue
        }

        if ($DeleteAfter) {
            $volumes = Get-ArchiveVolumes $file
            Remove-Item -LiteralPath $volumes -Force
            Write-Host "Deleted: $($volumes -join ', ')"
        }
    }
}

function global:7z-create {
    <#
    .SYNOPSIS
        Create an archive from files/folders with 7-Zip.
    .PARAMETER Destination
        Output archive path. The extension selects the format (.7z, .zip, ...).
    .PARAMETER Path
        One or more files/directories to add to the archive.
    .PARAMETER Password
        Encrypt the archive with this password. For .7z archives the file names
        are encrypted too (header encryption).
    .PARAMETER Level
        Compression level 0-9 (0 = store/no compression, 9 = ultra). Default 5.
    .PARAMETER Volumes
        Split the archive into volumes of this size, e.g. 100m, 1g.
    .EXAMPLE
        7z-create out.7z .\src
        7z-create backup.7z .\a .\b -Password hunter2 -Level 9
        7z-create big.7z .\data -Volumes 100m
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Destination,
        [Parameter(Mandatory, Position = 1, ValueFromRemainingArguments)]
        [string[]]$Path,
        [string]$Password,
        [ValidateRange(0, 9)]
        [int]$Level = 5,
        [string]$Volumes
    )

    foreach ($p in $Path) {
        if (-not (Test-Path -LiteralPath $p)) {
            Write-Error "Path not found: $p"
            return
        }
    }

    $arguments = @("a", $Destination, "-mx=$Level", "-y")
    if ($Password) {
        $arguments += "-p$Password"
        # Header (file-name) encryption is a 7z-format-only feature.
        if ($Destination -match '\.7z$') { $arguments += "-mhe=on" }
    }
    if ($Volumes) { $arguments += "-v$Volumes" }
    $arguments += $Path

    7z @arguments

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Archive creation failed ($LASTEXITCODE): $Destination"
    }
}

function global:7z-list {
    <#
    .SYNOPSIS
        List the contents of an archive without extracting it.
    .PARAMETER Path
        Archive file.
    .PARAMETER Password
        Password for encrypted archives.
    .EXAMPLE
        7z-list archive.7z
        7z-list secret.zip -Password hunter2
    #>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path,
        [string]$Password
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Error "Archive not found: $Path"
        return
    }

    $arguments = @("l", $Path)
    if ($Password) { $arguments += "-p$Password" }

    7z @arguments
}
