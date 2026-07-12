<#
.SYNOPSIS
    Initialize Scoop, and install Scoop apps.
.NOTES
    https://github.com/ScoopInstaller/scoop
#>

# Scoop keeps user apps in <root>\apps, so a global dir nested in the root (or
# vice versa) makes global and user installs fight over the same tree.
function Test-PathNested([string] $Child, [string] $Parent) {
    $c = [IO.Path]::GetFullPath($Child).TrimEnd('\') + '\'
    $p = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase) -or
           $p.StartsWith($c, [StringComparison]::OrdinalIgnoreCase)
}

if (!(Get-Command "scoop" -ErrorAction SilentlyContinue)) {

    # Scoop refuses to install from an elevated shell: shims and app permissions
    # would end up owned by the admin account.
    if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Warning "This shell is elevated. Scoop must be installed from a normal (non-admin) shell."
        Write-Host "Open a regular PowerShell window and start a new session to install Scoop." -ForegroundColor Yellow
        return
    }

    # Every prompt below blocks forever in a non-interactive host (a script, CI, or
    # `pwsh -c`), which would hang the shell start.
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) { return }

    Write-Host "For the best experience, it is recommended to install Scoop." -ForegroundColor Yellow
    Write-Host "You can continue the installation or install Scoop manually, and then run this script again." -ForegroundColor Yellow
    $confirm = Read-Host -Prompt "Do you want to install Scoop? (y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") { return }

    $scoop_dir = Read-Host -Prompt "Enter the directory where you want to install Scoop (default: $env:USERPROFILE\scoop)"
    if (-not $scoop_dir) { $scoop_dir = "$env:USERPROFILE\scoop" }

    $scoop_global_dir = Read-Host -Prompt "Enter the directory for globally installed apps (default: $env:ProgramData\scoop)"
    if (-not $scoop_global_dir) { $scoop_global_dir = "$env:ProgramData\scoop" }

    while (Test-PathNested $scoop_global_dir $scoop_dir) {
        Write-Host "The global apps directory must not be inside the Scoop root (or contain it)." -ForegroundColor Red
        Write-Host "Scoop already uses '$scoop_dir\apps' for user apps." -ForegroundColor Red
        $scoop_global_dir = Read-Host -Prompt "Enter the directory for globally installed apps (default: $env:ProgramData\scoop)"
        if (-not $scoop_global_dir) { $scoop_global_dir = "$env:ProgramData\scoop" }
    }

    Write-Host "You can set a proxy for the installation." -ForegroundColor Yellow
    Write-Host "If you don't want to use a proxy, just press Enter." -ForegroundColor Yellow
    $install_proxy = Read-Host -Prompt "Enter proxy address (e.g. $global:PROXY_ADDRESS)"

    $installer_dir = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "downloads\cache"
    $installer     = Join-Path $installer_dir -ChildPath "install-scoop.ps1"
    if (-not (Test-Path $installer_dir)) { New-Item -Path $installer_dir -ItemType Directory -Force | Out-Null }

    Write-Host "Downloading the Scoop installer from get.scoop.sh..." -ForegroundColor Yellow
    try {
        $irm_args = @{ Uri = 'https://get.scoop.sh'; OutFile = $installer }
        if ($install_proxy) { $irm_args.Proxy = $install_proxy }
        Invoke-RestMethod @irm_args
        Write-Host "Downloaded the Scoop installer." -ForegroundColor Green
    } catch {
        Write-Error "Failed to download the Scoop installer: $($_.Exception.Message)"
        return
    }

    $install_args = @{
        ScoopDir       = $scoop_dir
        ScoopGlobalDir = $scoop_global_dir
    }
    if ($install_proxy) { $install_args.Proxy = $install_proxy }

    & $installer @install_args

    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-Error "Scoop installation failed. Please try again."
        return
    }

    $env:SCOOP = $scoop_dir
    $env:SCOOP_GLOBAL = $scoop_global_dir
    try {
        # Scoop is a per-user install: a machine-wide SCOOP would point every
        # account at this user's directory.
        [Environment]::SetEnvironmentVariable('SCOOP', $scoop_dir, 'User')
        [Environment]::SetEnvironmentVariable('SCOOP_GLOBAL', $scoop_global_dir, 'User')
    } catch {
        Write-Warning "Failed to set the SCOOP environment variable."
        Write-Host "Please add the SCOOP environment variable manually." -ForegroundColor Yellow
    }
    Write-Host "Scoop has been installed." -ForegroundColor Green

    if ($install_proxy) {
        & scoop config proxy $install_proxy
    }

    if (-not (Get-Command 'git' -ErrorAction SilentlyContinue)) {
        & scoop install git
    }

    if (Get-Command 'git' -ErrorAction SilentlyContinue) {
        $scoop_supported_buckets = @(& scoop bucket known)
        Write-Host "Available buckets:"
        for ($i = 0; $i -lt $scoop_supported_buckets.Length; $i++) {
            Write-Host "$i. " -NoNewline
            Write-Host "$($scoop_supported_buckets[$i])" -ForegroundColor Yellow
        }

        $buckets_to_add = @()
        $numbers = Read-Host -Prompt "Enter the numbers of buckets to add, separated by spaces (press Enter to skip)"
        foreach ($number in ($numbers -split '\s+' | Where-Object { $_ })) {
            $index = 0
            if (-not [int]::TryParse($number, [ref] $index) -or
                $index -lt 0 -or $index -ge $scoop_supported_buckets.Length) {
                Write-Host "Ignoring invalid bucket number: $number" -ForegroundColor Red
                continue
            }
            $buckets_to_add += $scoop_supported_buckets[$index]
        }

        $scoop_existing_buckets = @(& scoop bucket list).Name
        foreach ($bucket in $buckets_to_add) {
            try {
                if ($scoop_existing_buckets -notcontains $bucket) {
                    & scoop bucket add $bucket
                }
            } catch {
                Write-Host "Failed to add $bucket bucket." -ForegroundColor Red
                continue
            }
            Write-Host "Added $bucket bucket." -ForegroundColor Green
        }
    } else {
        Write-Warning 'Git not found. You could add the buckets by running `scoop bucket add <bucket>` in PowerShell.'
    }

    Write-Host "Updating Scoop." -ForegroundColor Yellow
    & scoop update

    if ($?) {
        Write-Host "Scoop has been initialized." -ForegroundColor Green
    } else {
        Write-Warning 'Scoop updating failed. You can run `scoop update` to update Scoop again.'
    }
}

# If Scoop is still unavailable (not installed, or the user declined above),
# there is nothing left to configure — bail out before defining scoop-* helpers.
if (-not (Get-Command "scoop" -ErrorAction SilentlyContinue)) {
    return
}

$global:SCOOP_CATALOG_FILE = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "config\scoop\catalog.ps1"

function global:Find-ScoopCatalogEntry {
<#
.SYNOPSIS
    The catalog entry for an app, plus which catalog it came from, or $null.
#>
    param([Parameter(Mandatory)] [string] $App)

    foreach ($entry in $global:SCOOP_CATALOG) {
        if ($entry.Name -eq $App) { return @{ Meta = $entry; Tier = 'required' } }
    }
    foreach ($entry in $global:SCOOP_CATALOG_OPTIONAL) {
        if ($entry.Name -eq $App) { return @{ Meta = $entry; Tier = 'optional' } }
    }
    return $null
}

function global:scoop-info {
<#
.SYNOPSIS
    `scoop info`, with this repo's catalog metadata appended.
.DESCRIPTION
    Runs `scoop info <app>` and adds Category, Tier and Note from the catalogs when
    the app has an entry. An app with no entry is returned exactly as Scoop reported
    it — no placeholder fields.
.EXAMPLE
    scoop-info bat
    scoop-info ffmpeg
#>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $App
    )

    $info = & scoop info $App
    if (-not $info) { return }

    $known = Find-ScoopCatalogEntry -App $App
    if (-not $known) { return $info }

    $info | Add-Member -NotePropertyName 'Category' -NotePropertyValue $known.Meta.Category -Force
    $info | Add-Member -NotePropertyName 'Tier'     -NotePropertyValue $known.Tier          -Force
    $info | Add-Member -NotePropertyName 'Note'     -NotePropertyValue $known.Meta.Description -Force
    return $info
}

function global:scoop-install {
<#
.SYNOPSIS
    `scoop install`, then record the app in config\scoop\catalog.ps1.
.DESCRIPTION
    Installing without cataloguing is how apps end up unattributed: scoop-info has
    nothing to say about them. So after a successful install this offers to append an
    entry, defaulting the description to the one from the app's manifest.

    Apps already in a catalog are installed and left alone — $SCOOP_CATALOG is
    EasyPwsh's own list and is not edited from here.
.PARAMETER App
    App to install. May be bucket-qualified or version-pinned, as Scoop allows.
.PARAMETER Category
    Category to file it under. Prompted for when omitted.
.PARAMETER NoCatalog
    Install without touching the catalog.
.EXAMPLE
    scoop-install ffmpeg
    scoop-install ffmpeg -Category 'Media processing'
#>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $App,
        [string] $Category,
        [switch] $NoCatalog
    )

    & scoop install $App
    if ($LASTEXITCODE -ne 0) {
        Write-Error "scoop install $App failed."
        return
    }

    if ($NoCatalog) { return }

    # 'extras/ffmpeg@7.1' -> 'ffmpeg'
    $name = (($App -split '/')[-1] -split '@')[0]

    if (Find-ScoopCatalogEntry -App $name) {
        Write-Host "$name is already in a catalog." -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path $global:SCOOP_CATALOG_FILE)) {
        Write-Warning "Catalog not found, so $name was not recorded: $global:SCOOP_CATALOG_FILE"
        return
    }

    ($installed = @(& scoop list) | Where-Object { $_.Name -eq $name }) *>$null
    $bucket = if ($installed.Source) { $installed.Source } else { 'main' }

    $description = (& scoop info $name).Description
    if (-not $Category) {
        Write-Host "Recording $name in $($global:SCOOP_CATALOG_FILE)" -ForegroundColor Yellow
        $Category = Read-Host -Prompt "Category (Enter for 'unknown')"
    }
    if (-not $Category) { $Category = 'unknown' }

    $note = Read-Host -Prompt "Description (Enter for '$description')"
    if (-not $note) { $note = $description }

    # Single-quoted PowerShell strings escape a quote by doubling it.
    $entry = "    @{{ Bucket = '{0}'; Category = '{1}'; Name = '{2}'; Description = '{3}' }}" -f `
        $bucket, ($Category -replace "'", "''"), $name, ("$note" -replace "'", "''")

    $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $global:SCOOP_CATALOG_FILE)

    # Append just before the line that closes the array.
    $close = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i].Trim() -eq ')') { $close = $i; break }
    }
    if ($close -lt 0) {
        Write-Warning "Could not find the end of the catalog array; $name was not recorded."
        return
    }

    $lines.Insert($close, $entry)
    Set-Content -LiteralPath $global:SCOOP_CATALOG_FILE -Value $lines -Encoding UTF8

    $global:SCOOP_CATALOG_OPTIONAL += @{ Bucket = $bucket; Category = $Category; Name = $name; Description = $note }
    Write-Host "Recorded $name in the catalog." -ForegroundColor Green
}

function global:scoop-uninstall {
<#
.SYNOPSIS
    `scoop uninstall`, then drop the app from config\scoop\catalog.ps1.
.DESCRIPTION
    Scoop keeps <scoop>\persist\<app> — your app configuration — unless -Purge is
    given, so uninstalling and reinstalling does not lose settings.

    An app in $SCOOP_CATALOG (what Scoop itself needs) is refused: removing 7zip or
    git breaks Scoop's ability to install anything else.
.PARAMETER App
    App to uninstall.
.PARAMETER Purge
    Also delete persisted data. This is not reversible.
.PARAMETER NoCatalog
    Uninstall without touching the catalog.
.EXAMPLE
    scoop-uninstall ffmpeg
    scoop-uninstall ffmpeg -Purge
#>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $App,
        [switch] $Purge,
        [switch] $NoCatalog
    )

    $known = Find-ScoopCatalogEntry -App $App
    if ($known -and $known.Tier -eq 'required') {
        Write-Error "$App is required by Scoop itself ($($known.Meta.Description)). Refusing to uninstall."
        return
    }

    if ($Purge) { & scoop uninstall $App --purge } else { & scoop uninstall $App }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "scoop uninstall $App failed."
        return
    }
    if (-not $Purge) {
        Write-Host "Persisted data kept. Use -Purge to delete it too." -ForegroundColor DarkGray
    }

    if ($NoCatalog -or -not $known) { return }
    if (-not (Test-Path $global:SCOOP_CATALOG_FILE)) { return }

    $lines = @(Get-Content -LiteralPath $global:SCOOP_CATALOG_FILE)
    $kept = $lines | Where-Object { $_ -notmatch "^\s*@\{.*Name\s*=\s*'$([regex]::Escape($App))'" }

    if ($kept.Count -eq $lines.Count) {
        Write-Warning "$App was not found in $global:SCOOP_CATALOG_FILE; nothing removed."
        return
    }

    Set-Content -LiteralPath $global:SCOOP_CATALOG_FILE -Value $kept -Encoding UTF8
    $global:SCOOP_CATALOG_OPTIONAL = @($global:SCOOP_CATALOG_OPTIONAL | Where-Object { $_.Name -ne $App })
    Write-Host "Removed $App from the catalog." -ForegroundColor Green
}

function global:scoop-check-update {
    & scoop update

    ($scoop_apps_update = @(& scoop status | Where-Object { $_.'Latest Version' }).Name) *>$null

    foreach ($app in $scoop_apps_update) {
        if ($global:SCOOP_UPDATE_IGNORE -contains $app) {
            Write-Host "Ignored $app update." -ForegroundColor DarkYellow
            continue
        }
        Write-Host "Updating $app..." -ForegroundColor Yellow
        & scoop update $app
        Write-Host "Updated $app." -ForegroundColor Green
    }
}

function global:scoop-check-install {
    ($scoop_apps_installed = @(& scoop list).Name) *>$null

    foreach ($app in ($global:SCOOP_APPLICATION)) {
        if (-not ($scoop_apps_installed -contains $app)) {
            Write-Warning "$app is not found. Installing..."
            & scoop install $app
            Write-Host "Installed $app." -ForegroundColor Green
        } else {
            Write-Host "$app is already installed." -ForegroundColor Green
        }
    }
}

function global:scoop-check-failed {
    ($scoop_apps_failed = @(& scoop status | Where-Object { $_.Info -match 'failed' }).Name) *>$null

    foreach ($app in $scoop_apps_failed) {
        try {
            Write-Host "$app failed to install. Uninstalling..." -ForegroundColor Red
            & scoop uninstall $app
        } catch {
            Write-Error "Failed to uninstall $app."
            continue
        }
        Write-Host "Uninstalled $app" -ForegroundColor Red
    }
}

function global:scoop-check {
    if ($global:SCOOP_CHECK_UPDATE) {
        try {
            Write-Host "⏳ (1/3) Checking scoop update..." -ForegroundColor Yellow
            scoop-check-update
            Write-Host "✅ Update check completed successfully." -ForegroundColor Green
        } catch {
            Write-Host "❌ Update check failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($global:SCOOP_CHECK_INSTALL) {
        try {
            Write-Host "⏳ (2/3) Checking scoop installation..." -ForegroundColor Yellow
            scoop-check-install
            Write-Host "✅ Installation check completed successfully." -ForegroundColor Green
        } catch {
            Write-Host "❌ Installation check failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    if ($global:SCOOP_CHECK_FAILED) {
        try {
            Write-Host "⏳ (3/3) Checking scoop failed..." -ForegroundColor Yellow
            scoop-check-failed
            Write-Host "✅ Failed apps check completed successfully." -ForegroundColor Green
        } catch {
            Write-Host "❌ Failed apps check failed: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function global:scoop-proxy-on {
    try {
        & scoop config proxy $global:PROXY_ADDRESS
    } catch {
        Write-Error "Failed to set Scoop proxy."
        return
    }
    Write-Host "Scoop proxy has been turned on ($global:PROXY_ADDRESS)." -ForegroundColor Green
}

function global:scoop-proxy-off {
    try {
        & scoop config rm proxy
    } catch {
        Write-Error "Failed to unset Scoop proxy."
        return
    }
    Write-Host "Scoop proxy has been turned off." -ForegroundColor Green
}

scoop-check
