<#
.SYNOPSIS
    Moves files and directories to the recycle bin.
.DESCRIPTION
    This PowerShell script moves specified files and directories to the recycle bin
    instead of permanently deleting them. It supports multiple paths and wildcards.
.PARAMETER Path
    The path(s) to the files or directories to move to recycle bin. Supports wildcards.
.PARAMETER Recurse
    If specified, recursively moves all items in specified directories.
.PARAMETER WhatIf
    Shows what would happen if the script runs. The files are not actually moved.
.EXAMPLE
    PS> ./move-to-recycle.ps1 -Path "old_file.txt"
.EXAMPLE
    PS> ./move-to-recycle.ps1 -Path "temp_folder" -Recurse
.EXAMPLE
    PS> ./move-to-recycle.ps1 -Path "*.bak" -WhatIf
.NOTES
    Author: KOBAYASHI
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Path,

    [switch]$Recurse,
    [switch]$WhatIf
)

# Add Shell32.Shell COM object for recycle bin operations
$shell = New-Object -ComObject Shell.Application
$recyclebin = $shell.Namespace(0xa)

function Move-ToRecycleBin {
    param (
        [string]$ItemPath
    )

    try {
        $item = Get-Item -Path $ItemPath -ErrorAction Stop

        if ($WhatIf) {
            Write-Host "What if: Moving '$($item.FullName)' to recycle bin"
            return
        }

        # Move item to recycle bin
        $recyclebin.MoveHere($item.FullName)
        Write-Host "Moved '$($item.FullName)' to recycle bin"
    }
    catch {
        Write-Error "Failed to move '$ItemPath': $_"
    }
}

foreach ($p in $Path) {
    try {
        # Get items based on path and parameters
        $items = if ($Recurse) {
            Get-Item -Path $p -ErrorAction Stop
            Get-ChildItem -Path $p -Recurse -ErrorAction Stop
        } else {
            Get-Item -Path $p -ErrorAction Stop
        }

        # Move each item to recycle bin
        foreach ($item in $items) {
            Move-ToRecycleBin -ItemPath $item.FullName
        }
    }
    catch {
        Write-Error "Error processing path '$p': $_"
    }
}

# Clean up COM object
[System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
Remove-Variable shell