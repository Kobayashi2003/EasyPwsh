#
<#
.SYNOPSIS
    Organizes a single artist's works into different language categories
.DESCRIPTION
    This PowerShell script processes an artist's works folders structure:
    artists/
    └── artist_name/
        └── works_folder/
            ├── cn/         (Chinese translations)
            ├── jp/         (Japanese originals)
            └── en/         (English translations)
.PARAMETER Path
    Specifies the artist folder path to organize (e.g., "D:\Artists\ArtistName")
.EXAMPLE
    PS> ./organize-artist-works-step1.ps1 "D:\Artists\ArtistName"
.EXAMPLE
    PS> ./organize-artist-works-step1.ps1 -Path "C:\Downloads\Artist"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

# Chinese translation group patterns
$cnPatterns = @(
    '無邪気漢化組', '脸肿汉化组', '种植园汉化', 'CE家族社',
    '漢化', '汉化', '个人', '個人', '新桥月白日语社',
    '中文', '禁漫天堂', '重嵌', '漫遊中的蟲譯', '制作',
    '中国语', '中国語', '自用翻译', 'KK數位', '青文出版',
    '火车站骑空团', '改图', '自嵌', '翻译', '机翻', '機翻',
    '如月工房', '中国翻訳', '中国翻译', 'chinese', '240603去码',
    '未来數位', '冊語草堂', '52H里漫画组', '东方小吃店',
    '活力少女戰線', '風的工房', 'YUKI飛雪之城', '神猫出版社',
    '悠月工房', '改圖', '指○奶茶步兵團', '言耽社', 'eve去码',
    '240203去码', 'ydrss整合', '裹之夢境'
)

# Japanese original patterns
$jpPatterns = @('日原版')

# English translation patterns
$enPatterns = @('英訳', '英文')

function Move-ToCategory {
    param (
        [System.IO.DirectoryInfo[]]$folders,
        [string]$path,
        [string]$category,
        [string]$categoryName
    )
    if ($folders.Count -gt 0) {
        # Only create category folder if we have files to move
        $categoryPath = Join-Path $path $category
        if (-not (Test-Path -LiteralPath $categoryPath)) {
            New-Item -ItemType Directory -Path $categoryPath | Out-Null
            Write-Host "Created category folder: $category" -ForegroundColor Cyan
        }

        foreach ($folder in $folders) {
            Move-Item -LiteralPath $folder.FullName -Destination $categoryPath -Force
            Write-Host "Moved '$($folder.FullName)' to $categoryName" -ForegroundColor Green
        }
    }
}

function Organize-WorksFolder {
    param (
        [string]$worksPath,
        [string]$worksName
    )
    Write-Host "`nProcessing works folder: $worksName" -ForegroundColor Yellow

    # Get all subdirectories except cn/jp/en
    $allDirs = Get-ChildItem -LiteralPath $worksPath -Directory |
               Where-Object { $_.Name -notin @("cn", "jp", "en") }

    # Move Chinese translations
    $cnPattern = $cnPatterns -join '|'
    $cnFolders = $allDirs | Where-Object { $_.Name -match $cnPattern }
    if ($cnFolders.Count -gt 0) {
        Move-ToCategory -folders $cnFolders -path $worksPath -category "cn" -categoryName "Chinese translations"
    } else {
        Write-Host "No Chinese translations found for artist: $worksName" -ForegroundColor Red
    }

    # Move Japanese originals
    $jpPattern = $jpPatterns -join '|'
    $jpFolders = $allDirs | Where-Object { $_.Name -match $jpPattern }
    if ($jpFolders.Count -gt 0) {
        Move-ToCategory -folders $jpFolders -path $worksPath -category "jp" -categoryName "Japanese originals"
    } else {
        Write-Host "No Japanese originals found for artist: $worksName" -ForegroundColor Red
    }

    # Move English translations
    $enPattern = $enPatterns -join '|'
    $enFolders = $allDirs | Where-Object { $_.Name -match $enPattern }
    if ($enFolders.Count -gt 0) {
        Move-ToCategory -folders $enFolders -path $worksPath -category "en" -categoryName "English translations"
    } else {
        Write-Host "No English translations found for artist: $worksName" -ForegroundColor Red
    }
}

try {
    # Validate path
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path does not exist: $Path"
    }

    # Convert to absolute path
    $Path = (Resolve-Path $Path).Path

    Write-Host "Processing artist's works folders..."
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
        Write-Progress -Activity "Organizing Artist's Works" `
                      -Status "Folder $currentFolder of $totalFolders : $($worksFolder.Name)" `
                      -PercentComplete $percentComplete

        Organize-WorksFolder -worksPath $worksFolder.FullName -worksName $worksFolder.Name
    }

    Write-Progress -Activity "Organizing Artist's Works" -Completed
    Write-Host "`nAll works folders organized successfully!" -ForegroundColor Green
    exit 0 # success
} catch {
    "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber) : $($Error[0])"
    exit 1
}