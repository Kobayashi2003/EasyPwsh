<#
.SYNOPSIS
	Removes duplicate files in a directory
.DESCRIPTION
	This PowerShell script identifies duplicate files by calculating file content hash and removes duplicates based on priority rules.
	Deletion priority rules:
	1. Keep files without Windows duplicate number suffix (e.g., "(1)", "(2)") in filename
	2. Keep files with newer modification time
.PARAMETER Path
	Specifies the directory path to scan
.PARAMETER Depth
	Specifies the recursive depth level (0 = current directory only, -1 = unlimited recursion, default: -1)
.PARAMETER Algorithm
	Specifies the hash algorithm (MD5, SHA1, SHA256), default: SHA256
.EXAMPLE
	PS> ./remove-duplicate-files.ps1 -Path "C:\MyFolder"
	Scans C:\MyFolder and all subdirectories, removes duplicate files
.EXAMPLE
	PS> ./remove-duplicate-files.ps1 -Path "C:\MyFolder" -Depth 2
	Scans C:\MyFolder and 2 levels of subdirectories only
.EXAMPLE
	PS> ./remove-duplicate-files.ps1 -Path "C:\MyFolder" -Algorithm MD5
	Uses MD5 algorithm to calculate file hash
.LINK
	https://github.com/fleschutz/PowerShell
.NOTES
	Author: Kiro | License: CC0
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$Path = "",

    [Parameter(Mandatory = $false)]
    [int]$Depth = -1,

    [Parameter(Mandatory = $false)]
    [ValidateSet('MD5', 'SHA1', 'SHA256')]
    [string]$Algorithm = 'SHA256'
)

function Test-HasDuplicateNumber {
    param([string]$fileName)

    # Detects if filename contains Windows duplicate number pattern, e.g., "file (1).txt", "file (2).txt"
    return $fileName -match '\s*\(\d+\)\.[^.]+$'
}

function Get-FilesWithDepth {
    param(
        [string]$rootPath,
        [int]$maxDepth
    )

    if ($maxDepth -eq 0) {
        # Get files in current directory only
        return Get-ChildItem -LiteralPath $rootPath -File
    }
    elseif ($maxDepth -eq -1) {
        # Unlimited recursion
        return Get-ChildItem -LiteralPath $rootPath -File -Recurse
    }
    else {
        # Recursion with specified depth
        $files = @()
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@{Path = $rootPath; Level = 0})

        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $currentPath = $current.Path
            $currentLevel = $current.Level

            # Get files in current directory
            $files += Get-ChildItem -LiteralPath $currentPath -File

            # Add subdirectories to queue if not at max depth
            if ($currentLevel -lt $maxDepth) {
                $subDirs = Get-ChildItem -LiteralPath $currentPath -Directory
                foreach ($dir in $subDirs) {
                    $queue.Enqueue(@{Path = $dir.FullName; Level = $currentLevel + 1})
                }
            }
        }

        return $files
    }
}

try {
    # Get directory path
    if ($Path -eq "") {
        $Path = Read-Host "Enter directory path to scan"
    }

    # Validate path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Directory does not exist: $Path"
    }

    $Path = (Resolve-Path -LiteralPath $Path).Path

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Duplicate File Removal Tool" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Scan Directory: $Path" -ForegroundColor Yellow
    Write-Host "Recursion Depth: $(if ($Depth -eq -1) { 'Unlimited' } else { $Depth })" -ForegroundColor Yellow
    Write-Host "Hash Algorithm: $Algorithm" -ForegroundColor Yellow
    Write-Host ""

    # Get all files
    Write-Host "Scanning files..." -ForegroundColor Green
    $files = Get-FilesWithDepth -rootPath $Path -maxDepth $Depth

    if ($files.Count -eq 0) {
        Write-Host "No files found." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Found $($files.Count) files, calculating hashes..." -ForegroundColor Green

    # Calculate file hashes and group them
    $hashTable = @{}
    $processedCount = 0

    foreach ($file in $files) {
        $processedCount++
        if ($processedCount % 10 -eq 0 -or $processedCount -eq $files.Count) {
            Write-Progress -Activity "Calculating file hashes" -Status "Progress: $processedCount / $($files.Count)" -PercentComplete (($processedCount / $files.Count) * 100)
        }

        try {
            $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm $Algorithm).Hash

            if (-not $hashTable.ContainsKey($hash)) {
                $hashTable[$hash] = @()
            }

            $hashTable[$hash] += @{
                File = $file
                Hash = $hash
                HasDuplicateNumber = Test-HasDuplicateNumber -fileName $file.Name
            }
        }
        catch {
            Write-Host "Warning: Unable to calculate hash for file: $($file.FullName)" -ForegroundColor Yellow
        }
    }

    Write-Progress -Activity "Calculating file hashes" -Completed

    # Find duplicate files
    $duplicateGroups = $hashTable.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 }

    if ($duplicateGroups.Count -eq 0) {
        Write-Host ""
        Write-Host "✔️  No duplicate files found." -ForegroundColor Green
        exit 0
    }

    Write-Host ""
    Write-Host "Found $($duplicateGroups.Count) groups of duplicate files." -ForegroundColor Yellow
    Write-Host ""

    # Analyze each duplicate group and determine files to delete
    $filesToDelete = @()
    $groupNumber = 0

    foreach ($group in $duplicateGroups) {
        $groupNumber++
        $duplicates = $group.Value

        Write-Host "----------------------------------------" -ForegroundColor Cyan
        Write-Host "Duplicate Group #$groupNumber (Hash: $($group.Key.Substring(0, 16))...)" -ForegroundColor Cyan
        Write-Host "File Count: $($duplicates.Count)" -ForegroundColor White
        Write-Host ""

        # Sorting rules:
        # 1. Keep files without duplicate number suffix (HasDuplicateNumber = $false comes first)
        # 2. Keep files with newer modification time
        $sortedDuplicates = $duplicates | Sort-Object -Property @(
            @{Expression = {$_.HasDuplicateNumber}; Ascending = $true},
            @{Expression = {$_.File.LastWriteTime}; Descending = $true}
        )

        # Keep first file, delete the rest
        $fileToKeep = $sortedDuplicates[0]
        $filesToDeleteInGroup = $sortedDuplicates[1..($sortedDuplicates.Count - 1)]

        Write-Host "  [KEEP] $($fileToKeep.File.FullName)" -ForegroundColor Green
        Write-Host "         Size: $([math]::Round($fileToKeep.File.Length / 1KB, 2)) KB" -ForegroundColor Gray
        Write-Host "         Modified: $($fileToKeep.File.LastWriteTime)" -ForegroundColor Gray
        Write-Host ""

        foreach ($fileInfo in $filesToDeleteInGroup) {
            Write-Host "  [DELETE] $($fileInfo.File.FullName)" -ForegroundColor Red
            Write-Host "           Size: $([math]::Round($fileInfo.File.Length / 1KB, 2)) KB" -ForegroundColor Gray
            Write-Host "           Modified: $($fileInfo.File.LastWriteTime)" -ForegroundColor Gray
            Write-Host ""

            $filesToDelete += $fileInfo.File
        }
    }

    # Display statistics
    $totalSizeToFree = ($filesToDelete | Measure-Object -Property Length -Sum).Sum

    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Statistics" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Duplicate Groups: $($duplicateGroups.Count)" -ForegroundColor White
    Write-Host "Files to Delete: $($filesToDelete.Count)" -ForegroundColor White
    Write-Host "Space to Free: $([math]::Round($totalSizeToFree / 1MB, 2)) MB" -ForegroundColor White
    Write-Host ""

    # Request user confirmation
    Write-Host "WARNING: This operation will permanently delete the above files!" -ForegroundColor Red
    $confirmation = Read-Host "Confirm deletion? (Type 'YES' to confirm)"

    if ($confirmation -ne "YES") {
        Write-Host ""
        Write-Host "Operation cancelled." -ForegroundColor Yellow
        exit 0
    }

    # Execute deletion
    Write-Host ""
    Write-Host "Deleting files..." -ForegroundColor Green
    $deletedCount = 0
    $failedCount = 0

    foreach ($file in $filesToDelete) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force
            $deletedCount++
            Write-Host "  Deleted: $($file.Name)" -ForegroundColor Gray
        }
        catch {
            $failedCount++
            Write-Host "  Failed to delete: $($file.FullName) - $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "✔️  Operation completed!" -ForegroundColor Green
    Write-Host "Successfully deleted: $deletedCount files" -ForegroundColor Green
    if ($failedCount -gt 0) {
        Write-Host "Failed to delete: $failedCount files" -ForegroundColor Red
    }
    Write-Host "Space freed: $([math]::Round($totalSizeToFree / 1MB, 2)) MB" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""

    exit 0 # success
}
catch {
    Write-Host ""
    Write-Host "⚠️ Error: $($Error[0])" -ForegroundColor Red
    Write-Host "Line: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Red
    exit 1
}
