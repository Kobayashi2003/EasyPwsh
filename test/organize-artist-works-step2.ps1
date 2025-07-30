#
<#
.SYNOPSIS
    Reorganizes artist's works from language-based structure to artist-level language folders
.DESCRIPTION
    This PowerShell script processes an artist's works structure that has been organized by step1:
    Input structure:
    artists/
    └── artist_name/
        └── works_folder/
            ├── cn/         (Chinese translations)
            ├── jp/         (Japanese originals)
            └── en/         (English translations)

    Output structure:
    artists/
    └── artist_name/
        ├── 中/
        │   └── works_folder/
        │       └── [content from cn/]
        ├── 日/
        │   └── works_folder/
        │       └── [content from jp/ + other files]
        └── 英/
            └── works_folder/
                └── [content from en/]

.PARAMETER Path
    Specifies the artist folder path to reorganize (e.g., "D:\Artists\ArtistName")
.EXAMPLE
    PS> ./organize-artist-works-step2.ps1 "D:\Artists\ArtistName"
.EXAMPLE
    PS> ./organize-artist-works-step2.ps1 -Path "C:\Downloads\Artist"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

function Move-LanguageContent {
    param (
        [string]$sourcePath,
        [string]$destinationPath,
        [string]$languageName
    )

    if (Test-Path -LiteralPath $sourcePath) {
        # Create destination directory if it doesn't exist
        if (-not (Test-Path -LiteralPath $destinationPath)) {
            New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
            Write-Host "Created directory: $destinationPath" -ForegroundColor Cyan
        }

        # Move all contents from source to destination
        $items = Get-ChildItem -LiteralPath $sourcePath
        if ($items.Count -gt 0) {
            foreach ($item in $items) {
                Move-Item -LiteralPath $item.FullName -Destination $destinationPath -Force
                Write-Host "Moved '$($item.Name)' to $languageName folder" -ForegroundColor Green
            }

            # Remove empty source directory
            Remove-Item -LiteralPath $sourcePath -Force
            Write-Host "Removed empty directory: $sourcePath" -ForegroundColor Yellow
        }

        return $true
    }
    return $false
}

function Move-OtherContent {
    param (
        [string]$worksPath,
        [string]$jpDestinationPath
    )

    # Get all items except cn, jp, en directories
    $otherItems = Get-ChildItem -LiteralPath $worksPath |
                  Where-Object { $_.Name -notin @("cn", "jp", "en") }

    if ($otherItems.Count -gt 0) {
        # Ensure JP destination exists
        if (-not (Test-Path -LiteralPath $jpDestinationPath)) {
            New-Item -ItemType Directory -Path $jpDestinationPath -Force | Out-Null
            Write-Host "Created directory: $jpDestinationPath" -ForegroundColor Cyan
        }

        foreach ($item in $otherItems) {
            Move-Item -LiteralPath $item.FullName -Destination $jpDestinationPath -Force
            Write-Host "Moved other content '$($item.Name)' to Japanese folder" -ForegroundColor Green
        }

        return $true
    }
    return $false
}

function Reorganize-WorksFolder {
    param (
        [string]$worksPath,
        [string]$worksName,
        [string]$artistPath
    )

    Write-Host "`nProcessing works folder: $worksName" -ForegroundColor Yellow

    # Define language folder mappings
    $languageFolders = @{
        "cn" = "中"
        "jp" = "日"
        "en" = "英"
    }

    $hasContent = @{
        "cn" = $false
        "jp" = $false
        "en" = $false
    }

    # Check which language folders have content
    foreach ($lang in $languageFolders.Keys) {
        $langPath = Join-Path $worksPath $lang
        if (Test-Path -LiteralPath $langPath) {
            $content = Get-ChildItem -LiteralPath $langPath
            if ($content.Count -gt 0) {
                $hasContent[$lang] = $true
            }
        }
    }

    # Check if there are other files/folders (not cn/jp/en)
    $otherItems = Get-ChildItem -LiteralPath $worksPath |
                  Where-Object { $_.Name -notin @("cn", "jp", "en") }
    if ($otherItems.Count -gt 0) {
        $hasContent["jp"] = $true  # Other content goes to Japanese folder
    }

    # Process each language that has content
    foreach ($lang in $languageFolders.Keys) {
        if ($hasContent[$lang]) {
            $chineseFolderName = $languageFolders[$lang]
            $artistLangPath = Join-Path $artistPath $chineseFolderName
            $destWorksPath = Join-Path $artistLangPath $worksName

            # Create artist-level language folder if it doesn't exist
            if (-not (Test-Path -LiteralPath $artistLangPath)) {
                New-Item -ItemType Directory -Path $artistLangPath -Force | Out-Null
                Write-Host "Created artist language folder: $chineseFolderName" -ForegroundColor Cyan
            }

            # Create works folder under language folder
            if (-not (Test-Path -LiteralPath $destWorksPath)) {
                New-Item -ItemType Directory -Path $destWorksPath -Force | Out-Null
                Write-Host "Created works folder: $destWorksPath" -ForegroundColor Cyan
            }

            # Move language-specific content
            $sourceLangPath = Join-Path $worksPath $lang
            Move-LanguageContent -sourcePath $sourceLangPath -destinationPath $destWorksPath -languageName $chineseFolderName

            # For Japanese folder, also move other content
            if ($lang -eq "jp") {
                Move-OtherContent -worksPath $worksPath -jpDestinationPath $destWorksPath
            }
        }
    }
}

try {
    # Validate path
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path does not exist: $Path"
    }

    # Convert to absolute path
    $Path = (Resolve-Path $Path).Path

    Write-Host "Reorganizing artist's works structure..."
    Write-Host "Artist Path: $Path"
    Write-Host ""

    # Get all works folders under the artist directory
    $worksFolders = Get-ChildItem -LiteralPath $Path -Directory

    # Calculate total for progress
    $totalFolders = $worksFolders.Count
    $currentFolder = 0

    # Process each works folder
    foreach ($worksFolder in $worksFolders) {
        $currentFolder++
        $percentComplete = ($currentFolder / $totalFolders) * 100
        Write-Progress -Activity "Reorganizing Artist's Works Structure" `
                      -Status "Folder $currentFolder of $totalFolders : $($worksFolder.Name)" `
                      -PercentComplete $percentComplete

        Reorganize-WorksFolder -worksPath $worksFolder.FullName -worksName $worksFolder.Name -artistPath $Path
    }

    # Clean up empty works folders
    $remainingWorksFolders = Get-ChildItem -LiteralPath $Path -Directory |
                            Where-Object { $_.Name -notin @("中", "日", "英") }

    foreach ($folder in $remainingWorksFolders) {
        $isEmpty = (Get-ChildItem -LiteralPath $folder.FullName).Count -eq 0
        if ($isEmpty) {
            Remove-Item -LiteralPath $folder.FullName -Force
            Write-Host "Removed empty works folder: $($folder.Name)" -ForegroundColor Yellow
        }
    }

    Write-Progress -Activity "Reorganizing Artist's Works Structure" -Completed
    Write-Host "`nArtist's works structure reorganized successfully!" -ForegroundColor Green
    Write-Host "Structure is now organized by language at artist level." -ForegroundColor Green
    exit 0 # success
} catch {
    "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber) : $($Error[0])"
    exit 1
}
