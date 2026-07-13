<#
.SYNOPSIS
    This script is used to declare some global variables,
    which will be declared before other scripts run
#>

$global:PSVERSION   = (Get-Host).Version.ToString()
$global:USERPROFILE = [Environment]::GetFolderPath("UserProfile")
$global:DESKTOP     = [Environment]::GetFolderPath("Desktop")
$global:DOCUMENTS   = [Environment]::GetFolderPath("MyDocuments")
$global:MUSIC       = [Environment]::GetFolderPath("MyMusic")
$global:PICTURES    = [Environment]::GetFolderPath("MyPictures")
$global:VIDEOS      = [Environment]::GetFolderPath("MyVideos")
$global:STARTUP     = [Environment]::GetFolderPath("Startup")
$global:STARTMENU   = [Environment]::GetFolderPath("StartMenu")
$global:FONTS       = [Environment]::GetFolderPath("Fonts")
$global:COOKIES     = [Environment]::GetFolderPath("Cookies")
$global:HISTORY     = [Environment]::GetFolderPath("History")
$global:TEMP        = [Environment]::GetFolderPath("Temp")
$global:APPDATA     = [Environment]::GetFolderPath("ApplicationData")
$global:LOCALAPPDATA= [Environment]::GetFolderPath("LocalApplicationData")
$global:WINDOWS     = [Environment]::GetFolderPath("Windows")
$global:SYSTEM      = [Environment]::GetFolderPath("System")
$global:SYSTEMX86   = [Environment]::GetFolderPath("SystemX86")
$global:PROGRAMFILES= [Environment]::GetFolderPath("ProgramFiles")
$global:PROGRAMFILESX86= [Environment]::GetFolderPath("ProgramFilesX86")

# ─── Feature flags ────────────────────────────────────────────────────────────

# Print a per-block/per-file timing table after loading (core\init.ps1).
# Default-only assignment: it may be pre-set before dot-sourcing init.ps1.
if ($null -eq $global:PROFILE_STARTUP) { $global:PROFILE_STARTUP = $false }

$global:SET_APPS_ALIAS  = $true

$global:IMPORT_MODULES  = $true
$global:CHECK_MODULES   = $false
$global:SHOW_MODULES    = $false

# Import $MODULES_OPTIONAL alongside the required $MODULES.
$global:MODULE_OPTIONAL_FLAG = $false

# Keep commands matching $HISTORY_SENSITIVE_PATTERN out of the PSReadLine history
# file (modules\module.PSReadLine.ps1). Off: everything is recorded.
$global:HISTORY_FILTER_SENSITIVE = $false
$global:HISTORY_SENSITIVE_PATTERN = 'password|asplaintext|token|key|secret'

# Buckets scoop-check-install may install from. Apps from an unlisted (or not
# added) bucket are skipped, but stay catalogued for scoop-info.
$global:SCOOP_BUCKET_FLAGS = [ordered]@{
    'main'     = $true
    'extras'   = $false
    'versions' = $false
    'java'     = $false
}


$global:SCOOP_CHECK_UPDATE = $true
$global:SCOOP_CHECK_FAILED = $true

$global:SCOOP_CHECK_INSTALL = $true
# Also install $SCOOP_CATALOG_OPTIONAL (config\scoop\catalog.ps1); the required
# $SCOOP_CATALOG is always installed.
$global:SCOOP_OPTIONAL_FLAG = $true


# Let apps\init-pixi.ps1 download and run the official pixi installer when pixi is
# missing. Off: a shell start should not execute a remote script unasked.
$global:PIXI_AUTO_INSTALL = $false

# Local HTTP proxy used by scoop-proxy-on and the claude wrapper (apps\init-claude.ps1).
$global:PROXY_ADDRESS = '127.0.0.1:7890'

# ─── App aliases ──────────────────────────────────────────────────────────────

$global:APPS_ALIAS = $( if (-not $SET_APPS_ALIAS) { @{} } else { @{} })

# ─── Scoop applications ───────────────────────────────────────────────────────
#
# Bucket / Category / Description are data, reported by scoop-info (apps\init-scoop.ps1).
#
# Required: what Scoop needs to install and update anything else. EasyPwsh itself
# requires nothing — every init-*.ps1 is guarded by Get-Command and degrades to the
# built-in behaviour. Merely nice-to-have tools belong in $SCOOP_CATALOG_OPTIONAL.
$global:SCOOP_CATALOG = @(
    @{ Bucket = 'main'; Category = 'Version control';     Name = 'git';               Description = 'Scoop needs it to add and update buckets' }

    # Scoop cannot unpack many manifests without these.
    @{ Bucket = 'main'; Category = 'Archive & packaging'; Name = '7zip';              Description = 'Scoop essential — archive extraction' }
    @{ Bucket = 'main'; Category = 'Archive & packaging'; Name = 'innounp';           Description = 'Scoop essential — Inno Setup installer unpacker' }
    @{ Bucket = 'main'; Category = 'Archive & packaging'; Name = 'dark';              Description = 'Scoop essential — WiX/MSI decompiler' }
    @{ Bucket = 'main'; Category = 'Archive & packaging'; Name = '7zip19.00-helper';  Description = 'Scoop essential — 7-Zip 19.00 for old Inno Setup installers' }

    # Nothing outside the main bucket is required.
)

# Optional: the per-machine list, kept in a gitignored file.
# See config\scoop\catalog.example.ps1 for the format and the full menu.
$global:SCOOP_CATALOG_OPTIONAL = @()
$scoop_catalog_file = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "config\scoop\catalog.ps1"
if (Test-Path $scoop_catalog_file) { . $scoop_catalog_file }

# ─── Scoop: the effective install list ────────────────────────────────────────

$global:SCOOP_APPLICATION = $(if (-not $SCOOP_CHECK_INSTALL) { @() } else {
    $scoop_buckets_added = (& scoop bucket list).Name

    $catalogs = @($global:SCOOP_CATALOG)
    if ($global:SCOOP_OPTIONAL_FLAG) { $catalogs += @($global:SCOOP_CATALOG_OPTIONAL) }

    @($catalogs |
        Where-Object { $global:SCOOP_BUCKET_FLAGS[$_.Bucket] -and ($scoop_buckets_added -contains $_.Bucket) } |
        ForEach-Object { $_.Name })
})

$global:SCOOP_UPDATE_IGNORE = @(
    'postgresql', 'mysql'
)

# ─── PowerShell modules ───────────────────────────────────────────────────────
#
# Same split as the Scoop catalogs above:
#   MODULES           Required. EasyPwsh's own code depends on these.
#   MODULES_OPTIONAL  Imported only when MODULE_OPTIONAL_FLAG is $true.
#
# The value is a version constraint: 'latest' or ==/>=/<=/>/< x.y.z. Modules are
# installed only when CHECK_MODULES is $true; otherwise it just constrains the import.

$global:MODULES = $( if (-not $IMPORT_MODULES) { @{} } else {
@{
    # --- Shell editing ---
    # Keybindings and prediction (modules\module.PSReadLine.ps1).
    # 2.3.4 is the last release supporting PowerShell < 7.2.
    "PSReadLine"         = $(if ($global:PSVERSION -ge "7.2.0") { "latest" } else { "==2.3.4" })
}})

$global:MODULES_OPTIONAL = $( if (-not $IMPORT_MODULES) { @{} } else {
@{
    # --- Banner ---
    # Only used by the commented-out banner in modules\module.WriteAscii.ps1.
    "WriteAscii"         = "latest"

    # --- Fuzzy finding ---
    # Needs the 'fzf' and 'fd' Scoop apps (config\scoop\catalog.ps1).
    # Note: it binds an 'fd' alias, which shadows the fd executable.
    # "PSFzf"              = $(if ($global:PSVERSION -ge "7.2.0") { "latest" } else { "==2.0.0" })

    # --- Listing & prompt ---
    # "Get-ChildItemColor" = "latest"   # colorized ls/l (modules\module.Get-ChildItemColor.ps1)
    # "Terminal-Icons"     = "latest"   # file-type icons in directory listings
    # "posh-git"           = "latest"   # git status in the prompt
}})
