#
<#
.SYNOPSIS
    Compares the contents of two folders with color-coded differences
.DESCRIPTION
    This PowerShell script compares two folders and shows differences with color coding:
    - Green: Files/folders that exist only in source
    - Red: Files/folders that exist only in target
    - Yellow: Files that exist in both but have different content
.PARAMETER SourcePath
    Specifies the source folder path
.PARAMETER TargetPath
    Specifies the target folder path
.PARAMETER Depth
    Specifies the recursion depth (default: -1 for unlimited)
.PARAMETER ShowOnly
    Specifies which differences to show: 'All' (default), 'OnlyInSource', 'OnlyInTarget', 'Different'
.EXAMPLE
    PS> ./compare-folders.ps1 C:\SourceFolder D:\TargetFolder
.EXAMPLE
    PS> ./compare-folders.ps1 -SourcePath "C:\Source" -TargetPath "D:\Target" -Depth 2 -ShowOnly "Different"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$TargetPath,

    [Parameter(Mandatory = $false)]
    [int]$Depth = -1,

    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'OnlyInSource', 'OnlyInTarget', 'Different')]
    [string]$ShowOnly = 'All'
)

function Get-FileHash256([string]$filePath) {
    try {
        return (Get-FileHash -Path $filePath -Algorithm SHA256).Hash
    } catch {
        return $null
    }
}

function Compare-Folders {
    param (
        [string]$sourcePath,
        [string]$targetPath,
        [int]$currentDepth,
        [int]$maxDepth
    )

    if ($maxDepth -ne -1 -and $currentDepth -gt $maxDepth) {
        return
    }

    # Get items from both folders
    $sourceItems = Get-ChildItem -Path $sourcePath -Force -ErrorAction SilentlyContinue
    $targetItems = Get-ChildItem -Path $targetPath -Force -ErrorAction SilentlyContinue

    # Create hashtables for faster lookup
    $targetDict = @{}
    foreach ($item in $targetItems) {
        $targetDict[$item.Name] = $item
    }

    # Compare items
    foreach ($sourceItem in $sourceItems) {
        $targetItem = $targetDict[$sourceItem.Name]

        if ($null -eq $targetItem) {
            # Item exists only in source
            if ($ShowOnly -in @('All', 'OnlyInSource')) {
                Write-Host "+ $($sourceItem.FullName)" -ForegroundColor Green
            }
        } else {
            # Item exists in both
            if ($sourceItem.PSIsContainer) {
                # For directories, recurse if within depth limit
                if ($maxDepth -eq -1 -or $currentDepth -lt $maxDepth) {
                    Compare-Folders -sourcePath $sourceItem.FullName -targetPath $targetItem.FullName `
                                 -currentDepth ($currentDepth + 1) -maxDepth $maxDepth
                }
            } else {
                # For files, compare content
                $sourceHash = Get-FileHash256 $sourceItem.FullName
                $targetHash = Get-FileHash256 $targetItem.FullName

                if ($sourceHash -ne $targetHash) {
                    if ($ShowOnly -in @('All', 'Different')) {
                        Write-Host "≠ $($sourceItem.FullName)" -ForegroundColor Yellow
                    }
                }
            }
            # Remove processed item from target dictionary
            $targetDict.Remove($sourceItem.Name)
        }
    }

    # Show remaining target items (exist only in target)
    if ($ShowOnly -in @('All', 'OnlyInTarget')) {
        foreach ($item in $targetDict.Values) {
            Write-Host "- $($item.FullName)" -ForegroundColor Red
        }
    }
}

try {
    # Validate paths
    if (-not (Test-Path -Path $SourcePath)) {
        throw "Source path does not exist: $SourcePath"
    }
    if (-not (Test-Path -Path $TargetPath)) {
        throw "Target path does not exist: $TargetPath"
    }

    # Convert to absolute paths
    $SourcePath = (Resolve-Path $SourcePath).Path
    $TargetPath = (Resolve-Path $TargetPath).Path

    Write-Host "Comparing folders..."
    Write-Host "Source: $SourcePath"
    Write-Host "Target: $TargetPath"
    Write-Host "Depth: $(if ($Depth -eq -1) { 'Unlimited' } else { $Depth })"
    Write-Host "Show: $ShowOnly"
    Write-Host ""

    # Start comparison
    Compare-Folders -sourcePath $SourcePath -targetPath $TargetPath -currentDepth 0 -maxDepth $Depth

    exit 0 # success
} catch {
    "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
    exit 1
}