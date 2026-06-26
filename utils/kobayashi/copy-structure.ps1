#
<#
.SYNOPSIS
    Copies folder structure with controllable depth and file options
.DESCRIPTION
    This PowerShell script copies a folder structure with the following features:
    - Controllable recursion depth
    - Option to create empty files or copy content
    - Option to include/exclude specific file patterns
    - Progress indication for large structures
.PARAMETER SourcePath
    Specifies the source folder path
.PARAMETER TargetPath
    Specifies the target folder path
.PARAMETER Depth
    Specifies the recursion depth (default: -1 for unlimited)
.PARAMETER CreateEmptyFiles
    If specified, creates empty files instead of copying content
.PARAMETER Include
    File patterns to include (e.g. "*.txt", "*.doc"), comma-separated
.PARAMETER Exclude
    File patterns to exclude (e.g. "*.exe", "*.dll"), comma-separated
.EXAMPLE
    PS> ./copy-structure.ps1 C:\SourceFolder D:\TargetFolder
.EXAMPLE
    PS> ./copy-structure.ps1 -SourcePath "C:\Source" -TargetPath "D:\Target" -Depth 2 -CreateEmptyFiles -Include "*.txt,*.doc" -Exclude "*.tmp"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$TargetPath,

    [Parameter(Mandatory = $false)]
    [int]$Depth = -1,

    [Parameter(Mandatory = $false)]
    [switch]$CreateEmptyFiles,

    [Parameter(Mandatory = $false)]
    [string]$Include = "*",

    [Parameter(Mandatory = $false)]
    [string]$Exclude = ""
)

function Copy-WithStructure {
    param (
        [string]$sourcePath,
        [string]$targetPath,
        [int]$currentDepth,
        [int]$maxDepth,
        [string[]]$includePatterns,
        [string[]]$excludePatterns,
        [switch]$createEmpty
    )

    # Stop if we've reached max depth
    if ($maxDepth -ne -1 -and $currentDepth -gt $maxDepth) {
        return
    }

    # Create target directory if it doesn't exist
    if (-not (Test-Path -Path $targetPath)) {
        New-Item -ItemType Directory -Path $targetPath | Out-Null
        Write-Host "Created directory: $targetPath" -ForegroundColor Cyan
    }

    # Get all items from source
    $items = Get-ChildItem -Path $sourcePath -Force

    # Calculate total items for progress
    $totalItems = $items.Count
    $currentItem = 0

    foreach ($item in $items) {
        $currentItem++
        $targetItem = Join-Path $targetPath $item.Name

        # Show progress
        $percentComplete = ($currentItem / $totalItems) * 100
        Write-Progress -Activity "Copying Structure" -Status "$($item.FullName)" `
                      -PercentComplete $percentComplete

        if ($item.PSIsContainer) {
            # For directories, recurse if within depth limit
            Copy-WithStructure -sourcePath $item.FullName -targetPath $targetItem `
                             -currentDepth ($currentDepth + 1) -maxDepth $maxDepth `
                             -includePatterns $includePatterns -excludePatterns $excludePatterns `
                             -createEmpty $createEmpty
        } else {
            # Check if file matches include/exclude patterns
            $shouldInclude = $false
            $shouldExclude = $false

            # Check include patterns
            foreach ($pattern in $includePatterns) {
                if ($item.Name -like $pattern) {
                    $shouldInclude = $true
                    break
                }
            }

            # Check exclude patterns
            foreach ($pattern in $excludePatterns) {
                if ($pattern -and $item.Name -like $pattern) {
                    $shouldExclude = $true
                    break
                }
            }

            # Process file if it should be included
            if ($shouldInclude -and -not $shouldExclude) {
                if ($createEmpty) {
                    # Create empty file
                    New-Item -ItemType File -Path $targetItem -Force | Out-Null
                    Write-Host "Created empty file: $targetItem" -ForegroundColor Green
                } else {
                    # Copy file with content
                    Copy-Item -Path $item.FullName -Destination $targetItem -Force
                    Write-Host "Copied file: $targetItem" -ForegroundColor Green
                }
            }
        }
    }

    Write-Progress -Activity "Copying Structure" -Completed
}

try {
    # Validate paths
    if (-not (Test-Path -Path $SourcePath)) {
        throw "Source path does not exist: $SourcePath"
    }

    # Convert paths to absolute
    $SourcePath = (Resolve-Path $SourcePath).Path
    $TargetPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TargetPath)

    # Convert include/exclude patterns to arrays
    $includePatterns = $Include.Split(',').Trim()
    $excludePatterns = if ($Exclude) { $Exclude.Split(',').Trim() } else { @() }

    Write-Host "Copying folder structure..."
    Write-Host "Source: $SourcePath"
    Write-Host "Target: $TargetPath"
    Write-Host "Depth: $(if ($Depth -eq -1) { 'Unlimited' } else { $Depth })"
    Write-Host "Create empty files: $CreateEmptyFiles"
    Write-Host "Include patterns: $($includePatterns -join ', ')"
    Write-Host "Exclude patterns: $(if ($excludePatterns) { $excludePatterns -join ', ' } else { 'None' })"
    Write-Host ""

    # Start copying
    Copy-WithStructure -sourcePath $SourcePath -targetPath $TargetPath `
                      -currentDepth 0 -maxDepth $Depth `
                      -includePatterns $includePatterns -excludePatterns $excludePatterns `
                      -createEmpty $CreateEmptyFiles

    Write-Host "`nCopy completed successfully!" -ForegroundColor Green
    exit 0 # success
} catch {
    "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
    exit 1
}