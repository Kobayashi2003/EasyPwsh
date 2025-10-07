#Requires -RunAsAdministrator

param(
    [ValidateSet("Disable", "Enable", "Status")]
    [string]$Action = "Status"
)

$registryPath = "HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"
$valueName = "FolderType"

function Get-Status {
    try {
        $value = Get-ItemProperty -Path $registryPath -Name $valueName -ErrorAction SilentlyContinue
        return ($value -and $value.$valueName -eq "NotSpecified") ? "Disabled" : "Enabled"
    }
    catch { return "Enabled" }
}

function Set-Disable {
    if (-not (Test-Path $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }
    Set-ItemProperty -Path $registryPath -Name $valueName -Value "NotSpecified" -Type String
    Write-Host "Folder type detection disabled" -ForegroundColor Green
}

function Set-Enable {
    if (Test-Path $registryPath) {
        $property = Get-ItemProperty -Path $registryPath -Name $valueName -ErrorAction SilentlyContinue
        if ($property) {
            Remove-ItemProperty -Path $registryPath -Name $valueName
        }
    }
    Write-Host "Folder type detection enabled" -ForegroundColor Green
}

switch ($Action) {
    "Disable" { Set-Disable }
    "Enable" { Set-Enable }
    "Status" {
        $status = Get-Status
        Write-Host "Status: $status" -ForegroundColor $(if ($status -eq "Disabled") { "Red" } else { "Green" })
    }
}