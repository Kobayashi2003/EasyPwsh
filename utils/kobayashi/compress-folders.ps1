<#
.SYNOPSIS
	Compresses each direct subfolder of a directory into its own archive
.DESCRIPTION
	This PowerShell script walks the direct subfolders of a directory and compresses
	each one into a separate archive. It supports passwords, volume splitting,
	recovery records (RAR only), integrity verification and optional deletion of the
	source folders once they have been archived.
.PARAMETER path
	Specifies the directory whose direct subfolders are compressed (current working directory by default)
.PARAMETER destination
	Specifies where the archives are written (same as -path by default)
.PARAMETER format
	Archive format: 7z (default), zip or rar. RAR requires WinRAR's rar.exe.
.PARAMETER level
	Compression level from 0 (store only) to 9 (ultra), 5 by default
.PARAMETER password
	Encrypts the archives with this password
.PARAMETER encryptHeaders
	Also encrypts the file names, so the archive listing needs the password too (7z and rar only)
.PARAMETER volumeSize
	Splits the archive into volumes of this size, e.g. 4g, 1900m, 500k (no splitting by default)
.PARAMETER splitThreshold
	Only splits folders larger than this size, e.g. 10g. Requires -volumeSize.
.PARAMETER recoveryPercent
	Adds a recovery record of this percentage. Only the RAR format supports this.
.PARAMETER threads
	Number of compression threads (decided by the archiver by default)
.PARAMETER deleteSource
	None (default), AfterEach (delete a folder as soon as its archive is verified)
	or AfterAll (delete every folder only after the whole run succeeded)
.PARAMETER recycle
	Moves deleted source folders to the recycle bin instead of deleting them permanently
.PARAMETER skipVerify
	Skips the integrity test of each archive. Source folders are never deleted without a passing test.
.PARAMETER filter
	Only compresses subfolders whose name matches one of these wildcards
.PARAMETER excludeFolder
	Skips subfolders whose name matches one of these wildcards
.PARAMETER exclude
	Excludes files and directories matching these wildcards from inside the archives, e.g. node_modules, *.tmp
.PARAMETER skipExisting
	Skips subfolders whose archive already exists (useful to resume an interrupted run)
.PARAMETER dryRun
	Prints what would happen without creating or deleting anything
.PARAMETER logFile
	Appends a log of the run to this file
.EXAMPLE
	PS> ./compress-folders.ps1 D:\Games
	⏳ Compressing 3 subfolder(s) of D:\Games into D:\Games
	✔️ Compressed 3 folders (12.4 GB -> 8.1 GB, 35% saved) in 214.5s.
.EXAMPLE
	PS> ./compress-folders.ps1 D:\Games -destination E:\Backup -password secret -encryptHeaders -deleteSource AfterEach
.EXAMPLE
	PS> ./compress-folders.ps1 D:\Games -format rar -recoveryPercent 5 -volumeSize 4g -splitThreshold 10g
.LINK
	https://github.com/Kobayashi2003/EasyPwsh
.NOTES
	Author: Kobayashi | License: MIT
#>

param(
    [string]$path = "$PWD",
    [string]$destination = "",

    [ValidateSet("7z", "zip", "rar")]
    [string]$format = "7z",
    [ValidateRange(0, 9)]
    [int]$level = 5,
    [string]$password = "",
    [switch]$encryptHeaders,

    [string]$volumeSize = "",
    [string]$splitThreshold = "",
    [ValidateRange(0, 100)]
    [int]$recoveryPercent = 0,
    [int]$threads = 0,

    [ValidateSet("None", "AfterEach", "AfterAll")]
    [string]$deleteSource = "None",
    [switch]$recycle,
    [switch]$skipVerify,

    [string[]]$filter = @(),
    [string[]]$excludeFolder = @(),
    [string[]]$exclude = @(),
    [switch]$skipExisting,

    [switch]$dryRun,
    [string]$logFile = ""
)

# Turns 4g / 1900m / 500k / 1234 into a byte count.
function ConvertTo-Bytes {
    param([string]$size, [string]$paramName)

    if ($size -notmatch '(?i)^\s*(?<num>\d+(\.\d+)?)\s*(?<unit>[kmgt]?)b?\s*$') {
        throw "-$paramName '$size' is not a valid size (expected e.g. 500k, 700m, 4g)"
    }

    $multiplier = switch ($Matches.unit.ToLower()) {
        "k"     { 1KB }
        "m"     { 1MB }
        "g"     { 1GB }
        "t"     { 1TB }
        default { 1 }
    }

    return [long]([double]$Matches.num * $multiplier)
}

function Format-Size {
    param([long]$bytes)

    foreach ($unit in "B", "KB", "MB", "GB", "TB") {
        if ($bytes -lt 1024 -or $unit -eq "TB") {
            return "$([math]::Round($bytes, 2)) $unit"
        }
        $bytes = $bytes / 1024
    }
}

function Write-Log {
    param([string]$message)

    if ($logFile) {
        "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $message" | Out-File -FilePath $logFile -Append -Encoding utf8
    }
}

function Get-FolderSize {
    param([string]$folder)

    $sum = Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    if ($null -eq $sum.Sum) { return [long]0 }
    return [long]$sum.Sum
}

# Every file 7z/rar may have produced for one archive: the archive itself plus
# any volumes (name.7z.001, name.part01.rar). Used to clean up before a rewrite
# and to report the final size.
function Get-ArchiveFiles {
    param([string]$archivePath)

    $dir = Split-Path -Parent $archivePath
    $name = Split-Path -Leaf $archivePath
    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $escapedName = [regex]::Escape($name)
    $escapedBase = [regex]::Escape($base)
    $pattern = "(?i)^($escapedName(\.\d{3})?|$escapedBase\.part\d+\.rar)$"

    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $pattern })
}

# Builds the archiver command line. 7z and rar take different flags for the
# same concepts, so each option is translated per tool rather than passed through.
function Get-CompressArgs {
    param([string]$archivePath, [string]$sourceFolder, [long]$volumeBytes)

    $arguments = @()

    if ($format -eq "rar") {
        # a = add, -r = recurse, -ep1 = strip the source folder prefix from stored paths
        $arguments += @("a", "-r", "-ep1", "-idq")
        $arguments += "-m$([math]::Min([math]::Round($level / 2.0), 5))"   # rar levels are 0..5

        if ($password) {
            if ($encryptHeaders) { $arguments += "-hp$password" } else { $arguments += "-p$password" }
        }
        if ($recoveryPercent -gt 0) { $arguments += "-rr$($recoveryPercent)p" }
        if ($volumeBytes -gt 0)     { $arguments += "-v$($volumeBytes)b" }
        if ($threads -gt 0)         { $arguments += @("-mt", "$threads") }
        foreach ($pattern in $exclude) { $arguments += "-x$pattern" }

        $arguments += @("-y", $archivePath, "$sourceFolder\*")
    }
    else {
        $arguments += @("a", "-t$format", "-bb0", "-bd", "-y")
        $arguments += "-mx=$level"

        if ($password) {
            $arguments += "-p$password"
            # zip has no header encryption; -mhe is a 7z-only feature.
            if ($encryptHeaders -and $format -eq "7z") { $arguments += "-mhe=on" }
        }
        if ($volumeBytes -gt 0) { $arguments += "-v$($volumeBytes)b" }
        if ($threads -gt 0)     { $arguments += "-mmt=$threads" }
        foreach ($pattern in $exclude) { $arguments += "-xr!$pattern" }

        $arguments += @($archivePath, "$sourceFolder\*")
    }

    return $arguments
}

function Get-TestArgs {
    param([string]$archivePath)

    if ($format -eq "rar") {
        $arguments = @("t", "-idq")
        if ($password) { $arguments += "-p$password" }
    }
    else {
        $arguments = @("t", "-bb0", "-bd", "-y")
        if ($password) { $arguments += "-p$password" }
    }

    return $arguments + @($archivePath)
}

function Remove-Folder {
    param([string]$folder)

    if ($recycle) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
            $folder,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
    }
    else {
        Remove-Item -LiteralPath $folder -Recurse -Force
    }
}

try {
    $stopWatch = [system.diagnostics.stopwatch]::startNew()

    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Directory '$path' does not exist or is not a directory"
    }
    $path = (Resolve-Path -LiteralPath $path).Path

    # Recovery records exist only in the RAR format: neither 7z nor zip can store
    # one, so asking for it with another format is a mistake worth stopping on.
    if ($recoveryPercent -gt 0 -and $format -ne "rar") {
        throw "-recoveryPercent requires -format rar: the $format format cannot store a recovery record"
    }
    if ($encryptHeaders -and -not $password) {
        throw "-encryptHeaders requires -password"
    }
    if ($encryptHeaders -and $format -eq "zip") {
        throw "-encryptHeaders requires -format 7z or rar: zip always stores file names in clear text"
    }
    if ($splitThreshold -and -not $volumeSize) {
        throw "-splitThreshold requires -volumeSize"
    }

    $exe = if ($format -eq "rar") { "rar" } else { "7z" }
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        if ($format -eq "rar") {
            throw "rar.exe not found. The RAR format needs WinRAR - install it with 'scoop install winrar', or use -format 7z."
        }
        throw "7z.exe not found. Install it with 'scoop install 7zip'."
    }

    $volumeBytes = if ($volumeSize) { ConvertTo-Bytes -size $volumeSize -paramName "volumeSize" } else { [long]0 }
    $thresholdBytes = if ($splitThreshold) { ConvertTo-Bytes -size $splitThreshold -paramName "splitThreshold" } else { [long]0 }

    if (-not $destination) { $destination = $path }
    if (-not (Test-Path -LiteralPath $destination -PathType Container)) {
        if ($dryRun) {
            Write-Host "🔍 Would create destination: $destination" -ForegroundColor DarkGray
        }
        else {
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
        }
    }
    else {
        $destination = (Resolve-Path -LiteralPath $destination).Path
    }

    $folders = Get-ChildItem -LiteralPath $path -Directory

    if ($filter.Count -gt 0) {
        $folders = $folders | Where-Object { $name = $_.Name; $filter | Where-Object { $name -like $_ } }
    }
    if ($excludeFolder.Count -gt 0) {
        $folders = $folders | Where-Object { $name = $_.Name; -not ($excludeFolder | Where-Object { $name -like $_ }) }
    }
    $folders = @($folders)

    if ($folders.Count -eq 0) {
        Write-Host "ℹ️ No subfolders to compress in $path" -ForegroundColor Cyan
        exit 0
    }

    Write-Host "⏳ Compressing $($folders.Count) subfolder$(if ($folders.Count -ne 1) {'s'}) of " -NoNewline
    Write-Host "$path" -NoNewline -ForegroundColor Green
    Write-Host " into " -NoNewline
    Write-Host "$destination" -ForegroundColor Green
    Write-Log "Run started: path=$path destination=$destination format=$format level=$level deleteSource=$deleteSource"

    $succeeded = @()   # folders whose archive was created (and verified, unless -skipVerify)
    $reclaimed = @()   # folders skipped by -skipExisting whose existing archive still checks out
    $failedCount = 0
    $skippedCount = 0
    $sourceBytes = [long]0
    $archiveBytes = [long]0

    foreach ($folder in $folders) {
        $archivePath = Join-Path $destination "$($folder.Name).$format"
        $existing = Get-ArchiveFiles -archivePath $archivePath

        if ($existing.Count -gt 0 -and $skipExisting) {
            Write-Host "⏭️  Skipping (archive exists): $($folder.Name)" -ForegroundColor DarkGray
            $skippedCount++

            # A resumed run still owes the caller the deletion that -deleteSource promised:
            # the archive is already there, so test it and let it retire its source folder,
            # otherwise folders archived by the interrupted run would be left behind forever.
            if ($deleteSource -ne "None") {
                if ($dryRun) {
                    Write-Host "🔍 Would verify the existing archive and delete: $($folder.FullName)" -ForegroundColor DarkGray
                    continue
                }

                if (-not $skipVerify) {
                    $sorted = @($existing | Sort-Object Name)
                    & $exe @(Get-TestArgs -archivePath $sorted[0].FullName) | Out-Null

                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "❌ Existing archive failed its integrity test, keeping the source: $($folder.Name)" -ForegroundColor Red
                        Write-Log "FAILED verify (existing): $($sorted[0].FullName) exit=$LASTEXITCODE"
                        $failedCount++
                        continue
                    }
                }

                if ($deleteSource -eq "AfterEach") {
                    Remove-Folder -folder $folder.FullName
                    Write-Host "🗑️  Deleted source: $($folder.Name)$(if ($recycle) {' (recycle bin)'})" -ForegroundColor DarkGray
                    Write-Log "DELETED (existing archive): $($folder.FullName)"
                }
                else {
                    $reclaimed += $folder
                }
            }
            continue
        }

        $folderBytes = Get-FolderSize -folder $folder.FullName

        # With a threshold, only folders above it are split; smaller ones stay a single file.
        $useVolumes = if ($volumeBytes -gt 0 -and $thresholdBytes -gt 0) {
            $folderBytes -gt $thresholdBytes
        } else {
            $volumeBytes -gt 0
        }
        $effectiveVolume = if ($useVolumes) { $volumeBytes } else { [long]0 }

        $compressArgs = Get-CompressArgs -archivePath $archivePath -sourceFolder $folder.FullName -volumeBytes $effectiveVolume

        if ($dryRun) {
            Write-Host "🔍 $exe $($compressArgs -join ' ')" -ForegroundColor DarkGray
            if ($deleteSource -ne "None") {
                Write-Host "🔍 Would delete: $($folder.FullName)" -ForegroundColor DarkGray
            }
            continue
        }

        # Stale volumes from a previous run would otherwise survive next to the new
        # archive and make the set look complete when it is not.
        foreach ($stale in $existing) { Remove-Item -LiteralPath $stale.FullName -Force }

        Write-Host "⏳ Compressing: " -NoNewline
        Write-Host "$($folder.Name)" -NoNewline -ForegroundColor Yellow
        Write-Host " ($(Format-Size $folderBytes))$(if ($useVolumes) {" split into $volumeSize volumes"})"

        & $exe @compressArgs | Out-Null

        # 7z returns 1 for warnings (e.g. a locked file was skipped), >= 2 for errors.
        if ($LASTEXITCODE -ge 2 -or ($format -eq "rar" -and $LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1)) {
            Write-Host "❌ Failed to compress: $($folder.Name) (exit code $LASTEXITCODE)" -ForegroundColor Red
            Write-Log "FAILED compress: $($folder.FullName) exit=$LASTEXITCODE"
            $failedCount++
            continue
        }
        if ($LASTEXITCODE -eq 1) {
            Write-Warning "Compressed with warnings (some files may have been skipped): $($folder.Name)"
            Write-Log "WARNING compress: $($folder.FullName)"
        }

        $produced = @(Get-ArchiveFiles -archivePath $archivePath | Sort-Object Name)

        if ($produced.Count -eq 0) {
            Write-Host "❌ No archive was produced for: $($folder.Name)" -ForegroundColor Red
            Write-Log "FAILED: no archive produced for $($folder.FullName)"
            $failedCount++
            continue
        }

        if (-not $skipVerify) {
            # A split set has no file at $archivePath: the archiver must be handed the
            # first volume (name.7z.001 / name.part1.rar), which then pulls in the rest.
            $testArgs = Get-TestArgs -archivePath $produced[0].FullName
            & $exe @testArgs | Out-Null

            if ($LASTEXITCODE -ne 0) {
                Write-Host "❌ Integrity test failed: $($folder.Name) (exit code $LASTEXITCODE)" -ForegroundColor Red
                Write-Log "FAILED verify: $($produced[0].FullName) exit=$LASTEXITCODE"
                $failedCount++
                continue
            }
        }

        $producedBytes = [long](($produced | Measure-Object -Property Length -Sum).Sum)
        $sourceBytes += $folderBytes
        $archiveBytes += $producedBytes

        Write-Host "✔️ Archived: " -NoNewline -ForegroundColor Green
        Write-Host "$($folder.Name)" -NoNewline -ForegroundColor Yellow
        Write-Host " -> $(Format-Size $producedBytes)$(if ($produced.Count -gt 1) {" in $($produced.Count) volumes"})" -ForegroundColor Green
        Write-Log "OK: $($folder.FullName) -> $archivePath ($producedBytes bytes)"

        $succeeded += $folder

        if ($deleteSource -eq "AfterEach") {
            Remove-Folder -folder $folder.FullName
            Write-Host "🗑️  Deleted source: $($folder.Name)$(if ($recycle) {' (recycle bin)'})" -ForegroundColor DarkGray
            Write-Log "DELETED: $($folder.FullName)"
        }
    }

    if ($deleteSource -eq "AfterAll" -and -not $dryRun) {
        if ($failedCount -gt 0) {
            Write-Host "⚠️ Keeping all source folders: $failedCount folder$(if ($failedCount -ne 1) {'s'}) failed, so the run is not complete." -ForegroundColor Yellow
            Write-Log "SKIPPED AfterAll deletion: $failedCount failures"
        }
        else {
            foreach ($folder in ($succeeded + $reclaimed)) {
                Remove-Folder -folder $folder.FullName
                Write-Host "🗑️  Deleted source: $($folder.Name)$(if ($recycle) {' (recycle bin)'})" -ForegroundColor DarkGray
                Write-Log "DELETED: $($folder.FullName)"
            }
        }
    }

    $stopWatch.Stop()
    $elapsed = $stopWatch.Elapsed.TotalSeconds.ToString('F1')

    if ($dryRun) {
        Write-Host "🔍 Dry run: nothing was written or deleted." -ForegroundColor Cyan
        exit 0
    }

    $ratio = if ($sourceBytes -gt 0) { ", $([math]::Round((1 - $archiveBytes / $sourceBytes) * 100))% saved" } else { "" }
    Write-Host "✔️ Compressed $($succeeded.Count) folder$(if ($succeeded.Count -ne 1) {'s'}) ($(Format-Size $sourceBytes) -> $(Format-Size $archiveBytes)$ratio) in ${elapsed}s." -ForegroundColor Green
    if ($skippedCount -gt 0) { Write-Host "⏭️  Skipped $skippedCount existing archive$(if ($skippedCount -ne 1) {'s'})." -ForegroundColor DarkGray }
    Write-Log "Run finished: ok=$($succeeded.Count) failed=$failedCount skipped=$skippedCount elapsed=${elapsed}s"

    if ($failedCount -gt 0) {
        Write-Host "❌ $failedCount folder$(if ($failedCount -ne 1) {'s'}) failed." -ForegroundColor Red
        exit 1
    }
    exit 0
}
catch {
    Write-Host "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -ForegroundColor Red
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
