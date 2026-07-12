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

# Startup profiler: when $true, core/init.ps1 prints a per-block/per-file timing
# table at the end of loading. Default-only assignment so it can be pre-set before
# dot-sourcing init.ps1 (e.g. `$global:PROFILE_STARTUP=$true; . core\init.ps1`)
# without being clobbered here.
if ($null -eq $global:PROFILE_STARTUP) { $global:PROFILE_STARTUP = $false }

$global:SET_APPS_ALIAS  = $true

$global:IMPORT_MODULES  = $true
$global:CHECK_MODULES   = $false
$global:SHOW_MODULES    = $false

# When $true, $MODULES_RECOMMAND is imported alongside the required $MODULES.
$global:MODULE_RECOMMAND_FLAG = $false

# When $true, commands matching $HISTORY_SENSITIVE_PATTERN are kept out of the
# PSReadLine history file (modules\module.PSReadLine.ps1). Off by default, which
# is the existing behaviour: everything is recorded.
$global:HISTORY_FILTER_SENSITIVE = $false
$global:HISTORY_SENSITIVE_PATTERN = 'password|asplaintext|token|key|secret'

$global:SCOOP_MAIN_FLAG    = $true
$global:SCOOP_EXTRAS_FLAG  = $false
$global:SCOOP_VERSION_FLAG = $false

# The *_RECOMMAND arrays below are nice-to-have apps, not requirements. They are
# only installed by scoop-check-install when this is $true; the unsuffixed arrays
# (what EasyPwsh itself depends on) are always installed.
$global:SCOOP_RECOMMAND_FLAG = $false

$global:SCOOP_CHECK_UPDATE = $false
$global:SCOOP_CHECK_INSTALL = $false
$global:SCOOP_CHECK_FAILED = $false

# When $true, apps\init-pixi.ps1 may download and run the official pixi installer
# if pixi is missing. Off by default: a shell start should never execute a remote
# script without being asked.
$global:PIXI_AUTO_INSTALL = $false

# Local HTTP proxy used by scoop-proxy-on and the claude wrapper (apps\init-claude.ps1).
$global:PROXY_ADDRESS = '127.0.0.1:7890'

# ─── App aliases ──────────────────────────────────────────────────────────────

$global:APPS_ALIAS = $( if (-not $SET_APPS_ALIAS) { @{} } else { @{} })

# ─── Scoop applications ───────────────────────────────────────────────────────
#
# Bucket / Category / Description are data, so scoop-list (apps\init-scoop.ps1)
# can report them. The SCOOP_APPLICATION_* arrays below are derived from these
# two catalogs.
#
# Comment out an entry to stop installing it. Note that a commented-out entry is
# invisible at runtime, so scoop-list reports it as 'unknown' if you install it
# by hand.

# Required: EasyPwsh's own code depends on every entry here, and each Description
# names what needs it. Always installed when SCOOP_CHECK_INSTALL is on.
$global:SCOOP_CATALOG = @(
    @{ Bucket = 'main'; Category = 'Version control';     Name = 'git';       Description = 'Repo name in the prompt (start\prompt.ps1) and the PSReadLine git keybindings' }

    # These ARE the EasyPwsh shell experience.
    @{ Bucket = 'main'; Category = 'Shell utilities';     Name = 'bat';       Description = 'Backs the `cat` alias (apps\init-bat.ps1)' }
    @{ Bucket = 'main'; Category = 'Shell utilities';     Name = 'ripgrep';   Description = 'Backs the `grep` alias (apps\init-ripgrep.ps1)' }
    @{ Bucket = 'main'; Category = 'Shell utilities';     Name = 'zoxide';    Description = 'Backs the `cd` alias (apps\init-zoxide.ps1)' }
    @{ Bucket = 'main'; Category = 'Shell utilities';     Name = 'gsudo';     Description = 'Backs `sudo` (start\sudo.ps1, start\symlink.ps1)' }

    # Scoop's own mandatory essentials: it cannot install many manifests without them.
    @{ Bucket = 'main'; Category = 'Archive & packaging'; Name = '7zip';      Description = 'Scoop essential; also backs 7z-extract/7z-create/7z-list (apps\init-7z.ps1)' }
    @{ Bucket = 'main'; Category = 'Archive & packaging'; Name = 'innounp';   Description = 'Scoop essential — Inno Setup installer unpacker' }
    @{ Bucket = 'main'; Category = 'Archive & packaging'; Name = 'dark';      Description = 'Scoop essential — WiX/MSI decompiler' }

    # Nothing in the extras or versions buckets is required.
)

# Recommended: installed only when SCOOP_RECOMMAND_FLAG is $true.
$global:SCOOP_CATALOG_RECOMMAND = @(
    # --- main: editors ---
    @{ Bucket = 'main'; Category = 'Editors';             Name = 'vim';       Description = 'Modal text editor (apps\init-vim.ps1 links config\vim\_vimrc)' }
    # @{ Bucket = 'main'; Category = 'Editors';             Name = 'neovim';    Description = 'Hyperextensible Vim-based text editor' }

    # --- main: shell utilities ---
    @{ Bucket = 'main'; Category = 'Shell utilities';     Name = 'fzf';       Description = 'Command-line fuzzy finder — only used by the PSFzf module' }
    @{ Bucket = 'main'; Category = 'Shell utilities';     Name = 'fd';        Description = 'Fast alternative to find — only used by the PSFzf module' }
    @{ Bucket = 'main'; Category = 'Shell utilities';     Name = 'fastfetch'; Description = 'Fast system information tool (neofetch alternative)' }
    # @{ Bucket = 'main'; Category = 'Shell utilities';     Name = 'lf';        Description = 'Terminal file manager (apps\init-lf.ps1)' }
    # @{ Bucket = 'main'; Category = 'Shell utilities';     Name = 'yazi';      Description = 'Blazing fast terminal file manager (apps\init-yazi.ps1)' }

    # --- main: languages & runtimes ---
    @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'miniconda3'; Description = 'Minimal Python distribution with package manager (apps\init-conda.ps1)' }
    @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'nodejs';     Description = "JavaScript runtime built on Chrome's V8 engine" }
    @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'perl';       Description = 'Highly capable, feature-rich programming language' }
    # @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'jq';         Description = 'Lightweight JSON processor' }
    # @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'stylua';     Description = 'Lua code formatter and linter' }

    # --- main: archive & packaging ---
    # @{ Bucket = 'main'; Category = 'Archive & packaging'; Name = '7zip19.00-helper'; Description = 'Compatibility helper for old Inno Setup installers' }

    # --- main: media processing ---
    # @{ Bucket = 'main'; Category = 'Media processing';    Name = 'ffmpeg';      Description = 'Complete multimedia framework (apps\init-ffmpeg.ps1)' }
    # @{ Bucket = 'main'; Category = 'Media processing';    Name = 'chafa';       Description = 'Image to text converter for the terminal (apps\init-chafa.ps1)' }
    # @{ Bucket = 'main'; Category = 'Media processing';    Name = 'yt-dlp';      Description = 'Feature-rich video and audio downloader (apps\init-yt-dlp.ps1)' }
    # @{ Bucket = 'main'; Category = 'Media processing';    Name = 'imagemagick'; Description = 'Image manipulation and conversion toolkit' }
    # @{ Bucket = 'main'; Category = 'Media processing';    Name = 'scrcpy';      Description = 'Android device screen mirroring and control' }

    # --- main: document processing ---
    # @{ Bucket = 'main'; Category = 'Document processing'; Name = 'latex';       Description = 'Document typesetting system' }
    # @{ Bucket = 'main'; Category = 'Document processing'; Name = 'pandoc';      Description = 'Universal document converter' }
    # @{ Bucket = 'main'; Category = 'Document processing'; Name = 'prince';      Description = 'HTML to PDF converter' }
    # @{ Bucket = 'main'; Category = 'Document processing'; Name = 'poppler';     Description = 'PDF rendering utilities' }
    # @{ Bucket = 'main'; Category = 'Document processing'; Name = 'ghostscript'; Description = 'PostScript/PDF interpreter and renderer' }
    # @{ Bucket = 'main'; Category = 'Document processing'; Name = 'graphviz';    Description = 'Graph visualization and diagram generation' }

    # --- main: databases ---
    # @{ Bucket = 'main'; Category = 'Databases';           Name = 'redis';       Description = 'In-memory data structure store and database' }
    # @{ Bucket = 'main'; Category = 'Databases';           Name = 'mysql';       Description = 'Popular open-source relational database' }
    # @{ Bucket = 'main'; Category = 'Databases';           Name = 'postgresql';  Description = 'Advanced open-source relational database' }

    # --- main: networking ---
    # @{ Bucket = 'main'; Category = 'Networking';          Name = 'ngrok';       Description = 'Secure tunnel exposing a local service to the internet' }
    # @{ Bucket = 'main'; Category = 'Networking';          Name = 'aria2';       Description = 'Multi-protocol download utility' }

    # --- extras: git tooling ---
    @{ Bucket = 'extras'; Category = 'Git tooling';            Name = 'posh-git';        Description = 'PowerShell Git integration with enhanced prompts' }
    @{ Bucket = 'extras'; Category = 'Git tooling';            Name = 'lazygit';         Description = 'Simple terminal UI for git commands' }

    # --- extras: editors ---
    # @{ Bucket = 'extras'; Category = 'Editors';                Name = 'vscode';          Description = 'Lightweight but powerful source code editor' }

    # --- extras: desktop & productivity ---
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'altsnap';         Description = 'Window management tool for easy resizing/moving' }
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'powertoys';       Description = 'Set of tools for Windows to enhance productivity' }
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'everything';      Description = 'Instant file and folder search engine' }
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'quicklook';       Description = 'Quick file preview — bound to Ctrl+Space in modules\module.PSReadLine.ps1' }
    # @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'winmerge';        Description = 'Visual text file comparison and merging tool' }
    # @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'networkmanager';  Description = 'Network connection management tool' }
    # @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'registry-finder'; Description = 'Search and edit Windows registry entries' }

    # --- extras: system maintenance ---
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'recuva';          Description = 'File recovery software' }
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'ccleaner';        Description = 'System optimization and cleaning tool' }
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'geekuninstaller'; Description = 'Advanced uninstaller for complete software removal' }
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'hwmonitor';       Description = 'Hardware monitoring — temperature, voltage, fan speed' }
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'wiztree';         Description = 'Disk usage analyzer and file manager' }
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'filelight';       Description = 'Disk usage visualization' }
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'diskgenius';      Description = 'Disk partition management and data recovery' }
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'crystaldiskinfo'; Description = 'Disk health monitoring and S.M.A.R.T. analysis' }
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'crystaldiskmark'; Description = 'Disk benchmark utility' }

    # --- extras: media ---
    @{ Bucket = 'extras'; Category = 'Media';                  Name = 'imageglass';      Description = 'Lightweight and versatile image viewer' }
    # @{ Bucket = 'extras'; Category = 'Media';                  Name = 'vlc';             Description = 'Free and open-source media player' }
    # @{ Bucket = 'extras'; Category = 'Media';                  Name = 'mpv';             Description = 'Free and open-source media player (apps\init-mpv.ps1)' }

    # --- extras: remote & streaming ---
    # @{ Bucket = 'extras'; Category = 'Remote & streaming';     Name = 'putty';           Description = 'SSH and telnet client for Windows' }
    # @{ Bucket = 'extras'; Category = 'Remote & streaming';     Name = 'moonlight';       Description = 'NVIDIA GameStream client for game streaming' }
    # @{ Bucket = 'extras'; Category = 'Remote & streaming';     Name = 'sunshine';        Description = 'Self-hosted game streaming server' }

    # --- extras: networking ---
    @{ Bucket = 'extras'; Category = 'Networking';             Name = 'clash-verge-rev'; Description = 'GUI for Clash, a rule-based network tunnel in Go' }

    # --- extras: other ---
    # @{ Bucket = 'extras'; Category = 'Other';                  Name = 'bandizip';        Description = 'Archive manager with high compression ratio' }
    # @{ Bucket = 'extras'; Category = 'Other';                  Name = 'cheat-engine';    Description = 'Memory scanner and debugger for games' }

    # --- versions: toolchains ---
    @{ Bucket = 'versions'; Category = 'Toolchains';           Name = 'tdm-gcc';         Description = 'TDM-GCC compiler collection for Windows' }
)

# ─── Scoop: the install lists derived from the catalogs ───────────────────────

function global:Get-ScoopCatalogNames {
    param (
        [Parameter(Mandatory = $true)] [array]  $Catalog,
        [Parameter(Mandatory = $true)] [string] $Bucket
    )
    @($Catalog | Where-Object { $_.Bucket -eq $Bucket } | ForEach-Object { $_.Name })
}

$global:SCOOP_APPLICATION_MAIN    = $( if (-not $SCOOP_MAIN_FLAG)    { @() } else { Get-ScoopCatalogNames -Catalog $global:SCOOP_CATALOG -Bucket 'main' })
$global:SCOOP_APPLICATION_EXTRAS  = $( if (-not $SCOOP_EXTRAS_FLAG)  { @() } else { Get-ScoopCatalogNames -Catalog $global:SCOOP_CATALOG -Bucket 'extras' })
$global:SCOOP_APPLICATION_VERSION = $( if (-not $SCOOP_VERSION_FLAG) { @() } else { Get-ScoopCatalogNames -Catalog $global:SCOOP_CATALOG -Bucket 'versions' })

$global:SCOOP_APPLICATION_MAIN_RECOMMAND    = $( if (-not $SCOOP_MAIN_FLAG)    { @() } else { Get-ScoopCatalogNames -Catalog $global:SCOOP_CATALOG_RECOMMAND -Bucket 'main' })
$global:SCOOP_APPLICATION_EXTRAS_RECOMMAND  = $( if (-not $SCOOP_EXTRAS_FLAG)  { @() } else { Get-ScoopCatalogNames -Catalog $global:SCOOP_CATALOG_RECOMMAND -Bucket 'extras' })
$global:SCOOP_APPLICATION_VERSION_RECOMMAND = $( if (-not $SCOOP_VERSION_FLAG) { @() } else { Get-ScoopCatalogNames -Catalog $global:SCOOP_CATALOG_RECOMMAND -Bucket 'versions' })

$global:SCOOP_APPLICATION = $(if (-not $SCOOP_CHECK_INSTALL) { @() } else {
    $scoop_buckets = (& scoop bucket list).Name

    $required = @() + `
    $(if ($scoop_buckets -contains "main")     { $global:SCOOP_APPLICATION_MAIN }    else { @() }) + `
    $(if ($scoop_buckets -contains "extras")   { $global:SCOOP_APPLICATION_EXTRAS }  else { @() }) + `
    $(if ($scoop_buckets -contains "versions") { $global:SCOOP_APPLICATION_VERSION } else { @() })

    $recommand = $(if (-not $global:SCOOP_RECOMMAND_FLAG) { @() } else {
        @() + `
        $(if ($scoop_buckets -contains "main")     { $global:SCOOP_APPLICATION_MAIN_RECOMMAND }    else { @() }) + `
        $(if ($scoop_buckets -contains "extras")   { $global:SCOOP_APPLICATION_EXTRAS_RECOMMAND }  else { @() }) + `
        $(if ($scoop_buckets -contains "versions") { $global:SCOOP_APPLICATION_VERSION_RECOMMAND } else { @() })
    })

    $required + $recommand
})

$global:SCOOP_UPDATE_IGNORE = @(
    'postgresql', 'mysql'
)

# ─── PowerShell modules ───────────────────────────────────────────────────────
#
# Same split as the Scoop arrays above:
#
#   MODULES            Required. EasyPwsh's own code depends on these.
#   MODULES_RECOMMAND  Optional. Only imported when MODULE_RECOMMAND_FLAG is $true.
#
# The value is a version constraint: 'latest', or one of ==x.y.z / >=x.y.z /
# <=x.y.z / >x.y.z / <x.y.z. It is only *installed* when CHECK_MODULES is $true;
# otherwise it just constrains the import.

$global:MODULES = $( if (-not $IMPORT_MODULES) { @{} } else {
@{
    # --- Shell editing ---
    # The entire keybinding/prediction experience (modules\module.PSReadLine.ps1).
    # 2.3.4 is the last release supporting PowerShell < 7.2.
    "PSReadLine"         = $(if ($global:PSVERSION -ge "7.2.0") { "latest" } else { "==2.3.4" })
}})

$global:MODULES_RECOMMAND = $( if (-not $IMPORT_MODULES) { @{} } else {
@{
    # --- Banner ---
    # Only used by the commented-out banner in modules\module.WriteAscii.ps1.
    "WriteAscii"         = "latest"

    # --- Fuzzy finding ---
    # Needs the 'fzf' and 'fd' Scoop apps (see SCOOP_APPLICATION_MAIN_RECOMMAND).
    # Note: it binds an 'fd' alias, which shadows the fd executable.
    # "PSFzf"              = $(if ($global:PSVERSION -ge "7.2.0") { "latest" } else { "==2.0.0" })

    # --- Listing & prompt ---
    # "Get-ChildItemColor" = "latest"   # colorized ls/l (modules\module.Get-ChildItemColor.ps1)
    # "Terminal-Icons"     = "latest"   # file-type icons in directory listings
    # "posh-git"           = "latest"   # git status in the prompt
}})
