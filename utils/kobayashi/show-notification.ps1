<#
.SYNOPSIS
    Shows Windows notifications using WScript.Shell.
.DESCRIPTION
    This script displays Windows popup notifications with customizable
    title, message, duration, and icon type.
.PARAMETER Message
    The message to display in the notification.
.PARAMETER Title
    The title of the notification. Defaults to "Notification".
.PARAMETER Duration
    How long to display the notification (in seconds). Use 0 for indefinite. Default is 0.
.PARAMETER Type
    The type of notification icon to display:
    - Information (16)
    - Warning (48)
    - Error (16)
    - None (0)
    Default is Information.
.EXAMPLE
    PS> ./Show-Notification.ps1 -Message "Task completed!" -Title "Status" -Duration 5
.EXAMPLE
    PS> ./Show-Notification.ps1 -Message "Warning: Low disk space" -Type Warning
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [Parameter()]
    [string]$Title = "Notification",

    [Parameter()]
    [int]$Duration = 0,

    [Parameter()]
    [ValidateSet("Information", "Warning", "Error", "None")]
    [string]$Type = "Information"
)

try {
    $shell = New-Object -ComObject WScript.Shell

    # Convert type string to integer value
    $iconType = switch ($Type) {
        "Information" { 64 }
        "Warning" { 48 }
        "Error" { 16 }
        "None" { 0 }
    }

    # Show notification
    # Return values: 1 = OK, 2 = Cancel, 3 = Abort, 4 = Retry, 5 = Ignore, 6 = Yes, 7 = No
    $result = $shell.Popup($Message, $Duration, $Title, $iconType)

    # Output result if needed
    switch ($result) {
        1 { Write-Host "User clicked OK" }
        2 { Write-Host "User clicked Cancel" }
        3 { Write-Host "User clicked Abort" }
        4 { Write-Host "User clicked Retry" }
        5 { Write-Host "User clicked Ignore" }
        6 { Write-Host "User clicked Yes" }
        7 { Write-Host "User clicked No" }
        -1 { Write-Host "Notification timed out" }
    }

    # Cleanup
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
    exit 0 # success
}
catch {
    Write-Error "Failed to show notification: $_"
    exit 1
}