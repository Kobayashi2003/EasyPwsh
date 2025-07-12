function Remove-ItemSafely {
    <#
    .SYNOPSIS
        Moves files and directories to the recycle bin instead of permanent deletion
    .DESCRIPTION
        This function replaces the standard Remove-Item (rm) cmdlet to safely move items
        to the recycle bin rather than deleting them permanently.
    .PARAMETER Path
        The path(s) to the items to be moved to recycle bin
    .PARAMETER Recurse
        If specified, recursively moves all items in directories
    .PARAMETER Force
        If specified, moves hidden and system files
    .PARAMETER WhatIf
        Shows what would happen if the command runs
    .EXAMPLE
        rm "old_file.txt"
    .EXAMPLE
        rm "temp_folder" -Recurse
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string[]]$Path,

        [switch]$Recurse,
        [switch]$Force
    )

    begin {
        $shell = New-Object -ComObject Shell.Application
        $recyclebin = $shell.Namespace(0xa)
    }

    process {
        foreach ($p in $Path) {
            try {
                # Get items based on path and parameters
                $items = if ($Recurse) {
                    if ($Force) {
                        Get-Item -Path $p -ErrorAction Stop -Force
                        Get-ChildItem -Path $p -Recurse -Force -ErrorAction Stop
                    } else {
                        Get-Item -Path $p -ErrorAction Stop
                        Get-ChildItem -Path $p -Recurse -ErrorAction Stop
                    }
                } else {
                    if ($Force) {
                        Get-Item -Path $p -ErrorAction Stop -Force
                    } else {
                        Get-Item -Path $p -ErrorAction Stop
                    }
                }

                # Move each item to recycle bin
                foreach ($item in $items) {
                    if ($PSCmdlet.ShouldProcess($item.FullName, "Move to recycle bin")) {
                        $recyclebin.MoveHere($item.FullName)
                        Write-Verbose "Moved '$($item.FullName)' to recycle bin"
                    }
                }
            }
            catch {
                Write-Error "Error processing path '$p': $_"
            }
        }
    }

    end {
        # Clean up COM object
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
        Remove-Variable shell
    }
}

# Set alias to override default rm
Set-Alias -Name 'rm' -Value 'Remove-ItemSafely' -Force -Option AllScope
