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
        [string]$Password,
        [bool]$DeleteAfterExtract
    )

    $cmd = "7z x `"$ArchivePath`" -o`"$ExtractPath`" -bb0 -bd"

    if ($Password) {
        $cmd += " -p`"$Password`""
    }

    $cmd += " -y"

    $result = Invoke-Expression $cmd 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to extract: $ArchivePath"
        Write-Host "Press any key to continue or Ctrl+C to exit..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        return $false
    } else {
        if ($DeleteAfterExtract) {
            Remove-Item -LiteralPath $ArchivePath -Force
            Write-Host "Deleted: $ArchivePath"
        }
        return $true
    }
}

if (-not (Test-Path $Path)) {
    Write-Error "Path does not exist: $Path"
    exit 1
}

$archiveExtensions = @("*.zip", "*.rar", "*.7z", "*.tar", "*.gz", "*.bz2", "*.xz", "*.tar.gz", "*.tar.bz2", "*.tar.xz")

foreach ($extension in $archiveExtensions) {
    $archives = Get-ChildItem -Path $Path -Filter $extension -Recurse -File

    foreach ($archive in $archives) {
        $extractPath = $archive.DirectoryName

        if ($CreateFolder) {
            $folderName = [System.IO.Path]::GetFileNameWithoutExtension($archive.Name)
            $extractPath = Join-Path $archive.DirectoryName $folderName

            if (-not (Test-Path $extractPath)) {
                New-Item -ItemType Directory -Path $extractPath -Force | Out-Null
            }
        }

        Write-Host "Extracting: $($archive.FullName) to $extractPath"
        Extract-Archive -ArchivePath $archive.FullName -ExtractPath $extractPath -Password $Password -DeleteAfterExtract $DeleteAfterExtract
    }
}

Write-Host "Extraction completed."