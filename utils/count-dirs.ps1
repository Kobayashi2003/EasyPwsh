<#
.SYNOPSIS
    Counts directories in specified paths.
.DESCRIPTION
    This PowerShell script counts the total number of directories in given paths
    with a specified depth limit.
.PARAMETER Path
    The directory path(s) to search in. Defaults to the current directory.
.PARAMETER Depth
    Maximum depth of subdirectories to search. If not specified, searches all subdirectories.
.PARAMETER ExcludePath
    The directory paths to exclude from counting.
.EXAMPLE
    PS> ./count-dirs.ps1 -Path C:\Projects -Depth 2
.EXAMPLE
    PS> ./count-dirs.ps1 -ExcludePath bin,obj
.NOTES
    Author: KOBAYASHI
#>

param(
    [string[]]$Path = ".",
    [int]$Depth,
    [string[]]$ExcludePath
)

$dirCount = 0
$depthStats = @{}

$getChildItemParams = @{
    Directory = $true
}

if ($Path) {
    $getChildItemParams.Path = $Path
}

if ($Depth) {
    $getChildItemParams.Depth = $Depth
    $getChildItemParams.Recurse = $true
} else {
    $getChildItemParams.Recurse = $true
}

$dirs = Get-ChildItem @getChildItemParams

# Convert ExcludePath to full paths for proper comparison
$excludeFullPaths = @()
if ($ExcludePath) {
    $excludeFullPaths = $ExcludePath | ForEach-Object { (Resolve-Path -Path $_ -ErrorAction SilentlyContinue).Path }
}

# Convert Path to full paths for base depth calculation
$basePaths = @()
foreach ($p in $Path) {
    $basePaths += (Resolve-Path $p).Path
}

foreach ($dir in $dirs) {
    # Skip directories in excluded paths
    $shouldExclude = $false
    foreach ($excludePath in $excludeFullPaths) {
        if ($dir.FullName.StartsWith($excludePath, [StringComparison]::OrdinalIgnoreCase)) {
            $shouldExclude = $true
            break
        }
    }
    if ($shouldExclude) { continue }

    $dirCount++

    # Calculate depth based on directory path segments compared to base path
    $dirFullPath = $dir.FullName
    $pathDepth = 1  # Default depth

    # Find which base path this directory belongs to
    foreach ($basePath in $basePaths) {
        if ($dirFullPath.StartsWith($basePath)) {
            # Calculate relative path
            $relPath = $dirFullPath.Substring($basePath.Length).Trim('\')
            if ($relPath) {
                # Count path segments to determine depth
                $pathDepth = ($relPath -split '\\').Count
            }
            break
        }
    }

    if (-not $depthStats.ContainsKey($pathDepth)) {
        $depthStats[$pathDepth] = 0
    }
    $depthStats[$pathDepth]++
}

Write-Host "Directory Depth Statistics:"
$depthStats.GetEnumerator() | Sort-Object Name | ForEach-Object {
    Write-Host "Depth $($_.Key): $($_.Value) directories"
}

Write-Host "`nTotal number of directories: $dirCount"

if ($dirCount -eq 0) {
    Write-Host "No directories found."
    exit 1
}

exit 0 # success
