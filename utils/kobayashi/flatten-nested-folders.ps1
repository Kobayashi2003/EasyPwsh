<#
.SYNOPSIS
	Flattens nested folders with identical names
.DESCRIPTION
	This PowerShell script processes folders in a given directory path.
	If a folder contains only one subfolder with the same name as the parent folder,
	it moves all contents from the subfolder to the parent folder and removes the empty subfolder.
.PARAMETER path
	Specifies the directory path to process (current working directory by default)
.PARAMETER recurse
	If specified, processes subdirectories recursively
.EXAMPLE
	PS> ./flatten-nested-folders.ps1 C:\Downloads
	⏳ Processing directory: C:\Downloads
	✔️ Flattened folder: MyApp\MyApp -> MyApp
	✔️ Processed 1 nested folder in 0.5s.
.EXAMPLE
	PS> ./flatten-nested-folders.ps1 C:\Downloads -recurse
	⏳ Processing directory recursively: C:\Downloads
	✔️ Flattened folder: MyApp\MyApp -> MyApp
	✔️ Flattened folder: SubDir\Tool\Tool -> SubDir\Tool
	✔️ Processed 2 nested folders in 1.2s.
.LINK
	https://github.com/Kobayashi2003/EasyPwsh
.NOTES
	Author: Kobayashi | License: MIT
#>

param(
    [string]$path = "$PWD",
    [switch]$recurse
)

try {
    $stopWatch = [system.diagnostics.stopwatch]::startNew()
    $processedCount = 0

    Write-Host "⏳ Processing directory$(if ($recurse) {' recursively'}): " -NoNewline
    Write-Host "$path" -ForegroundColor Green

    # Validate path
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Directory '$path' does not exist or is not a directory"
    }

    # Function to process a single directory
    function Process-Directory {
        param([string]$dirPath)

        try {
            $childItems = Get-ChildItem -LiteralPath $dirPath -Directory -ErrorAction Stop

            # Check if directory has exactly one subdirectory
            if ($childItems.Count -eq 1) {
                $parentDir = Get-Item -LiteralPath $dirPath
                $childDir = $childItems[0]

                # Check if child directory name matches parent directory name
                if ($childDir.Name -eq $parentDir.Name) {
                    Write-Host "⏳ Found nested folder: " -NoNewline
                    Write-Host "$($parentDir.Name)\$($childDir.Name)" -ForegroundColor Yellow

                    # Get all items in the child directory
                    $itemsToMove = Get-ChildItem -LiteralPath $childDir.FullName -Force

                    # Move all items from child to parent directory
                    foreach ($item in $itemsToMove) {
                        $destination = Join-Path $parentDir.FullName $item.Name

                        # Check if destination already exists
                        if (Test-Path -LiteralPath $destination) {
                            Write-Warning "Skipping '$($item.Name)' - already exists in parent directory"
                            continue
                        }

                        try {
                            Move-Item -LiteralPath $item.FullName -Destination $destination -Force
                        }
                        catch {
                            Write-Warning "Failed to move '$($item.Name)': $($_.Exception.Message)"
                        }
                    }

                    # Remove the now empty child directory
                    try {
                        Remove-Item -LiteralPath $childDir.FullName -Force -Recurse
                        Write-Host "✔️ Flattened folder: " -NoNewline -ForegroundColor Green
                        Write-Host "$($parentDir.Name)\$($childDir.Name)" -NoNewline -ForegroundColor Yellow
                        Write-Host " -> " -NoNewline
                        Write-Host "$($parentDir.Name)" -ForegroundColor Green
                        $script:processedCount++
                    }
                    catch {
                        Write-Warning "Failed to remove empty directory '$($childDir.FullName)': $($_.Exception.Message)"
                    }
                }
            }
        }
        catch {
            Write-Warning "Error processing directory '$dirPath': $($_.Exception.Message)"
        }
    }

    # Get directories to process
    if ($recurse) {
        $directories = Get-ChildItem -LiteralPath $path -Directory -Recurse | Sort-Object FullName -Descending
    }
    else {
        $directories = Get-ChildItem -LiteralPath $path -Directory
    }

    # Process each directory
    foreach ($directory in $directories) {
        Process-Directory -dirPath $directory.FullName
    }

    # Also process the root directory
    Process-Directory -dirPath $path

    $stopWatch.Stop()

    if ($processedCount -eq 0) {
        Write-Host "ℹ️ No nested folders found to flatten." -ForegroundColor Cyan
    }
    else {
        Write-Host "✔️ Processed $processedCount nested folder$(if ($processedCount -ne 1) {'s'}) in $($stopWatch.Elapsed.TotalSeconds.ToString('F1'))s." -ForegroundColor Green
    }
}
catch {
    Write-Error "❌ Error: $($_.Exception.Message)"
    exit 1
}
