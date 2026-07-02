param(
    [Parameter(Mandatory=$true)]
    [string]$Path,

    [Parameter(Mandatory=$false)]
    [string]$Password = "",

    [Parameter(Mandatory=$false)]
    [switch]$CreateFolder,

    [Parameter(Mandatory=$false)]
    [switch]$DeleteAfterExtract = $false
)

function Extract-Archive {
    param(
        [string]$ArchivePath,
        [string]$ExtractPath,
        [string]$Password
    )

    $cmd = "7z x `"$ArchivePath`" -o`"$ExtractPath`" -bb0 -bd"

    if ($Password) {
        $cmd += " -p`"$Password`""
    }

    $cmd += " -y"

    Invoke-Expression $cmd 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to extract: $ArchivePath"
        Write-Host "Press any key to continue or Ctrl+C to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return $false
    }

    return $true
}

# Classify an archive file. For multi-volume sets, only the first volume
# should be handed to 7z (it pulls in the continuation volumes automatically);
# the remaining volumes must be skipped so they are not extracted on their own.
# Returns a hashtable: IsContinuation, BaseName (folder/name without the volume suffix).
function Get-ArchivePartInfo {
    param([System.IO.FileInfo]$Archive)

    $name = $Archive.Name

    # New-style RAR: name.part1.rar, name.part01.rar, name.part001.rar
    if ($name -match '(?i)^(?<base>.+)\.part(?<num>\d+)\.rar$') {
        return @{
            IsContinuation = ([int]$Matches.num -ne 1)
            BaseName       = $Matches.base
            IsMultiVolume  = $true
        }
    }

    # Split volumes: name.ext.001, name.ext.002 ...  (e.g. name.7z.001, name.zip.001)
    if ($name -match '(?i)^(?<base>.+)\.(?<num>\d{3})$') {
        return @{
            IsContinuation = ([int]$Matches.num -ne 1)
            BaseName       = [System.IO.Path]::GetFileNameWithoutExtension($Matches.base)
            IsMultiVolume  = $true
        }
    }

    # Single archive: drop only the final extension for the folder name.
    return @{
        IsContinuation = $false
        BaseName       = [System.IO.Path]::GetFileNameWithoutExtension($name)
        IsMultiVolume  = $false
    }
}

# Find every file that belongs to the same multi-volume set as $Archive,
# so all volumes can be deleted together after a successful extraction.
function Get-VolumeSiblings {
    param([System.IO.FileInfo]$Archive)

    $info = Get-ArchivePartInfo -Archive $Archive
    if (-not $info.IsMultiVolume) {
        return @($Archive)
    }

    $escaped = [regex]::Escape($info.BaseName)
    $pattern = "(?i)^$escaped(\.part\d+\.rar|\.[^.]+\.\d{3})$"

    return Get-ChildItem -LiteralPath $Archive.DirectoryName -File |
        Where-Object { $_.Name -match $pattern }
}

try {
    if (-not (Test-Path $Path)) { throw "Path does not exist: $Path" }

    $archiveExtensions = @("*.zip", "*.rar", "*.7z", "*.tar", "*.gz", "*.bz2", "*.xz", "*.001")

    $seen = @{}

    foreach ($extension in $archiveExtensions) {
        $archives = Get-ChildItem -Path $Path -Filter $extension -Recurse -File

        foreach ($archive in $archives) {
            if ($seen.ContainsKey($archive.FullName)) { continue }
            $seen[$archive.FullName] = $true

            $info = Get-ArchivePartInfo -Archive $archive

            if ($info.IsContinuation) {
                Write-Host "⏭️  Skipping volume (part of a set): $($archive.Name)" -ForegroundColor DarkGray
                continue
            }

            $extractPath = $archive.DirectoryName

            if ($CreateFolder) {
                $extractPath = Join-Path $archive.DirectoryName $info.BaseName

                if (-not (Test-Path $extractPath)) {
                    New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
                }
            }

            Write-Host "⏳ Extracting: $($archive.FullName) to $extractPath" -ForegroundColor Yellow
            $success = Extract-Archive -ArchivePath $archive.FullName -ExtractPath $extractPath -Password $Password

            if ($success -and $DeleteAfterExtract) {
                foreach ($volume in Get-VolumeSiblings -Archive $archive) {
                    Remove-Item -LiteralPath $volume.FullName -Force
                    $seen[$volume.FullName] = $true
                    Write-Host "Deleted: $($volume.FullName)" -ForegroundColor DarkGray
                }
            }
        }
    }

    Write-Host "✔️ Extraction completed." -ForegroundColor Green
    exit 0 # success
} catch {
    Write-Host "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])" -ForegroundColor Red
    exit 1
}
