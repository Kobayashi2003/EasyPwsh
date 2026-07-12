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

function global:scoop-list {
<#
.SYNOPSIS
    List installed Scoop apps, annotated with the bucket, category and description
    from the catalogs in start\variables.ps1.
.DESCRIPTION
    Anything installed but absent from both catalogs — including entries that are
    commented out there — reports 'unknown' for the fields the catalog would have
    supplied. The bucket falls back to the source Scoop itself reports, so it is
    only 'unknown' when Scoop does not know it either.
.PARAMETER Bucket
    Only list apps from this bucket.
.PARAMETER Category
    Only list apps in this category. Use 'unknown' for the uncatalogued ones.
.PARAMETER Tier
    Only list apps of this tier: required, recommand, or unknown.
.EXAMPLE
    scoop-list
    scoop-list -Category unknown
    scoop-list -Bucket main -Tier required
    scoop-list | Where-Object Category -eq 'Databases'
#>
    param (
        [string] $Bucket,
        [string] $Category,
        [ValidateSet('required', 'recommand', 'unknown')]
        [string] $Tier
    )

    # The tier is not stored on the entries: it is which catalog they live in.
    $catalog = @{}
    foreach ($entry in $global:SCOOP_CATALOG_RECOMMAND) { $catalog[$entry.Name] = @{ Meta = $entry; Tier = 'recommand' } }
    foreach ($entry in $global:SCOOP_CATALOG)           { $catalog[$entry.Name] = @{ Meta = $entry; Tier = 'required' } }

    ($installed = @(& scoop list)) *>$null

    $result = foreach ($app in $installed) {
        $known = $catalog[$app.Name]
        $meta  = $known.Meta

        [PSCustomObject]@{
            Name        = $app.Name
            Version     = $app.Version
            Bucket      = @($meta.Bucket, $app.Source, 'unknown' | Where-Object { $_ })[0]
            Category    = @($meta.Category, 'unknown' | Where-Object { $_ })[0]
            Tier        = @($known.Tier, 'unknown' | Where-Object { $_ })[0]
            Description = @($meta.Description, 'unknown' | Where-Object { $_ })[0]
        }
    }

    if ($Bucket)   { $result = $result | Where-Object { $_.Bucket   -eq $Bucket } }
    if ($Category) { $result = $result | Where-Object { $_.Category -eq $Category } }
    if ($Tier)     { $result = $result | Where-Object { $_.Tier     -eq $Tier } }

    $result | Sort-Object Bucket, Category, Name
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
