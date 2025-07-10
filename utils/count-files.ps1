<#
.SYNOPSIS
    Counts files in specified directories.
.DESCRIPTION
    This PowerShell script counts the total number of files in given directories
    with a specified depth. It supports including or excluding file types.
.PARAMETER FileTypes
    The file extensions to include (e.g., "py", "txt"). If not specified, all file types are counted.
.PARAMETER ExcludeFileTypes
    The file extensions to exclude from counting.
.PARAMETER Path
    The directory path(s) to search in. Defaults to the current directory.
.PARAMETER Depth
    Maximum depth of subdirectories to search. If not specified, searches all subdirectories.
.EXAMPLE
    PS> ./count-files.ps1 -Path C:\Projects -Depth 2
.EXAMPLE
    PS> ./count-files.ps1 -FileTypes py,txt -ExcludePath bin,obj
.NOTES
    Author: KOBAYASHI
#>

param(
    [string[]]$FileTypes,
    [string[]]$ExcludeFileTypes,
    [string[]]$Path = ".",
    [int]$Depth,
    [string[]]$ExcludePath
)

$fileCount = 0
$typeStats = @{}

$getChildItemParams = @{
    File = $true
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

$files = Get-ChildItem @getChildItemParams

# Convert ExcludePath to full paths for proper comparison
$excludeFullPaths = @()
if ($ExcludePath) {
    $excludeFullPaths = $ExcludePath | ForEach-Object { (Resolve-Path -Path $_ -ErrorAction SilentlyContinue).Path }
}

foreach ($file in $files) {
    # Skip files in excluded paths
    $shouldExclude = $false
    foreach ($excludePath in $excludeFullPaths) {
        if ($file.FullName.StartsWith($excludePath, [StringComparison]::OrdinalIgnoreCase)) {
            $shouldExclude = $true
            break
        }
    }
    if ($shouldExclude) { continue }

    $extension = $file.Extension.TrimStart(".")

    if (($FileTypes -and $extension -notin $FileTypes) -or
        ($ExcludeFileTypes -and $extension -in $ExcludeFileTypes)) {
        continue
    }

    $fileCount++

    if (-not $typeStats.ContainsKey($extension)) {
        $typeStats[$extension] = 0
    }
    $typeStats[$extension]++
}

Write-Host "File Type Statistics:"
$typeStats.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object {
    Write-Host "$($_.Key): $($_.Value) files"
}

Write-Host "`nTotal number of files: $fileCount"

if ($fileCount -eq 0) {
    Write-Host "No matching files found."
    exit 1
}

exit 0 # success
