#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers or unregisters an "Open in Terminal (No Profile)" context menu entry.

.DESCRIPTION
    - Register   : Adds an "Open in Terminal (No Profile)" entry to the folder background context menu.
                   Use -Terminal to choose between WindowsTerminal, WindowsTerminalPreview, or PowerShell.
    - Unregister : Removes all three terminal menu entries at once.

.PARAMETER Action
    Register | Unregister

.PARAMETER Terminal
    Which terminal to register. Only used with -Action Register.
    WindowsTerminal        : Windows Terminal (stable)
    WindowsTerminalPreview : Windows Terminal Preview
    PowerShell             : Plain powershell.exe (default)

.EXAMPLE
    .\Add-ContextMenu-OpenTerminal.ps1 -Action Register -Terminal WindowsTerminal
    .\Add-ContextMenu-OpenTerminal.ps1 -Action Register -Terminal WindowsTerminalPreview
    .\Add-ContextMenu-OpenTerminal.ps1 -Action Register -Terminal PowerShell
    .\Add-ContextMenu-OpenTerminal.ps1 -Action Unregister
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Register', 'Unregister')]
    [string]$Action,

    [ValidateSet('WindowsTerminal', 'WindowsTerminalPreview', 'PowerShell')]
    [string]$Terminal = 'PowerShell'
)

# --- Helper: resolve the real .exe path for a UWP package --------------------
#
# UWP apps live under a versioned folder in:
#   C:\Program Files\WindowsApps\<PackageFullName>\
# The folder name changes with every update, so we query the registry
# (or Get-AppxPackage) to find the current install location at runtime.
#
function Get-UwpExePath {
    param(
        [string]$PackageFamilyName,   # e.g. "Microsoft.WindowsTerminal_8wekyb3d8bbwe"
        [string]$ExeName              # e.g. "wt.exe"
    )

    try {
        $pkg = Get-AppxPackage -Name ($PackageFamilyName -replace '_.*','') -ErrorAction Stop |
               Where-Object { $_.PackageFamilyName -eq $PackageFamilyName } |
               Select-Object -First 1

        if (-not $pkg) { return $null }

        $exePath = Join-Path $pkg.InstallLocation $ExeName
        if (Test-Path $exePath) { return $exePath }
    } catch { }

    return $null
}

# --- Terminal profiles --------------------------------------------------------

# Profiles are built at runtime so paths are always current.
function Get-TerminalProfiles {

    # --- Windows Terminal (stable) ---
    $wtExe = Get-UwpExePath -PackageFamilyName 'Microsoft.WindowsTerminal_8wekyb3d8bbwe' -ExeName 'wt.exe'

    # Fallback: the AppExecutionAlias in WindowsApps (always present if WT is installed)
    if (-not $wtExe) {
        $alias = "$env:LOCALAPPDATA\Microsoft\WindowsApps\wt.exe"
        if (Test-Path $alias) { $wtExe = $alias }
    }

    # --- Windows Terminal Preview ---
    $wtpExe = Get-UwpExePath -PackageFamilyName 'Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe' -ExeName 'wt.exe'

    if (-not $wtpExe) {
        $alias = "$env:LOCALAPPDATA\Microsoft\WindowsApps\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\wt.exe"
        if (Test-Path $alias) { $wtpExe = $alias }
    }

    return @{

        WindowsTerminal = @{
            MenuKey   = 'OpenTerminalNoProfile_WT'
            MenuLabel = 'Open in Windows Terminal (No Profile)'
            # Icon must be an absolute path; the AppExecutionAlias carries the real icon
            Icon      = if ($wtExe) { "$wtExe,0" } else { 'powershell.exe,0' }
            # cmd /c start launches the UWP alias properly without a visible cmd window
            # Using "start wt" lets Windows resolve the AppExecutionAlias correctly
            Command   = 'cmd.exe /c start wt.exe new-tab -d "%V" pwsh.exe -NoProfile -NoExit'
            ExePath   = $wtExe
        }

        WindowsTerminalPreview = @{
            MenuKey   = 'OpenTerminalNoProfile_WTP'
            MenuLabel = 'Open in Windows Terminal Preview (No Profile)'
            Icon      = if ($wtpExe) { "$wtpExe,0" } else { 'powershell.exe,0' }
            # For Preview the alias name differs; use the full alias path via cmd /c start
            Command   = if ($wtpExe) {
                            "cmd.exe /c start `"`" `"$wtpExe`" new-tab -d `"%V`" pwsh.exe -NoProfile -NoExit"
                        } else {
                            'cmd.exe /c start wt.exe new-tab -d "%V" pwsh.exe -NoProfile -NoExit'
                        }
            ExePath   = $wtpExe
        }

        PowerShell = @{
            MenuKey   = 'OpenTerminalNoProfile_PS'
            MenuLabel = 'Open in PowerShell (No Profile)'
            Icon      = 'powershell.exe,0'
            Command   = 'powershell.exe -NoProfile -NoExit -Command "Set-Location -LiteralPath ''%V''"'
            ExePath   = 'powershell.exe'
        }
    }
}

# --- Registry roots -----------------------------------------------------------

# Directory\Background : right-click on empty space inside a folder
# Directory            : right-click on a folder itself
# Drive\Background     : right-click on empty space at a drive root
$RegistryRoots = @(
    'HKCU:\SOFTWARE\Classes\Directory\Background\shell',
    'HKCU:\SOFTWARE\Classes\Directory\shell',
    'HKCU:\SOFTWARE\Classes\Drive\Background\shell'
)

# --- Functions ----------------------------------------------------------------

function Register-MenuItem {
    param([hashtable]$Profile)

    # Warn if the executable could not be located
    if (-not $Profile.ExePath) {
        Write-Warning "Could not locate the executable for '$($Profile.MenuLabel)'. The menu entry will be created but may not work until the application is installed."
    } else {
        Write-Host "    Executable : $($Profile.ExePath)" -ForegroundColor DarkGray
        Write-Host "    Icon       : $($Profile.Icon)"    -ForegroundColor DarkGray
        Write-Host "    Command    : $($Profile.Command)" -ForegroundColor DarkGray
        Write-Host ""
    }

    foreach ($root in $RegistryRoots) {
        $shellKey   = Join-Path $root $Profile.MenuKey
        $commandKey = Join-Path $shellKey 'command'

        # Create or open the shell\<MenuKey> key
        if (-not (Test-Path $shellKey)) {
            New-Item -Path $shellKey -Force | Out-Null
        }
        Set-ItemProperty -Path $shellKey -Name '(Default)' -Value $Profile.MenuLabel
        Set-ItemProperty -Path $shellKey -Name 'Icon'      -Value $Profile.Icon

        # Create or open the shell\<MenuKey>\command key
        if (-not (Test-Path $commandKey)) {
            New-Item -Path $commandKey -Force | Out-Null
        }
        Set-ItemProperty -Path $commandKey -Name '(Default)' -Value $Profile.Command

        Write-Host "[+] Registered: $shellKey" -ForegroundColor Green
    }

    Write-Host "`n✅ Registration complete! Right-click inside any folder to see: '$($Profile.MenuLabel)'" -ForegroundColor Cyan
}

function Unregister-AllMenuItems {
    param([hashtable]$Profiles)

    # Remove every known menu key regardless of which terminal was registered
    foreach ($profile in $Profiles.Values) {
        foreach ($root in $RegistryRoots) {
            $shellKey = Join-Path $root $profile.MenuKey

            if (Test-Path $shellKey) {
                Remove-Item -Path $shellKey -Recurse -Force
                Write-Host "[-] Removed: $shellKey" -ForegroundColor Yellow
            } else {
                Write-Host "[!] Not found (skipped): $shellKey" -ForegroundColor DarkGray
            }
        }
    }

    Write-Host "`n✅ Unregistration complete! All terminal menu entries have been removed." -ForegroundColor Cyan
}

# --- Entry point --------------------------------------------------------------

$profiles = Get-TerminalProfiles

switch ($Action) {
    'Register'   { Register-MenuItem -Profile $profiles[$Terminal] }
    'Unregister' { Unregister-AllMenuItems -Profiles $profiles }
}