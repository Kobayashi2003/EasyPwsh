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

$global:SET_APPS_ALIAS  = $true

$global:IMPORT_MODULES  = $true
$global:CHECK_MODULES   = $false
$global:SHOW_MODULES    = $false

$global:SCOOP_MAIN_FLAG    = $true
$global:SCOOP_EXTRAS_FLAG  = $false
$global:SCOOP_VERSION_FLAG = $false

$global:SCOOP_CHECK_UPDATE = $false
$global:SCOOP_CHECK_INSTALL = $false
$global:SCOOP_CHECK_FAILED = $false

# ─── App aliases ──────────────────────────────────────────────────────────────

$global:APPS_ALIAS = $( if (-not $SET_APPS_ALIAS) { @{} } else {
@{
    'steam'     = 'D:\Steam\Steam.exe'
    'pikpak'    = 'D:\Temp\PikPak\PikPak.exe'
    'wechat'    = 'C:\Program Files (x86)\Tencent\WeChat\WeChat.exe'
}})

# ─── Scoop: main bucket ───────────────────────────────────────────────────────

$global:SCOOP_APPLICATION_MAIN = $( if (-not $SCOOP_MAIN_FLAG) { @() } else {
@(

    # --- Editors ---
    'vim',          # Powerful modal text editor
    # 'neovim',       # Hyperextensible Vim-based text editor

    # --- Version control ---
    'git',          # Distributed version control system

    # --- Shell utilities ---
    'bat',          # Cat clone with syntax highlighting and Git integration
    'fd',           # Fast and user-friendly alternative to find
    'fzf',          # Command-line fuzzy finder
    'ripgrep',      # Fast regex-based text search tool
    'zoxide',       # Smart cd command that learns your habits
    'gsudo',        # Sudo implementation for Windows
    'fastfetch',    # Fast system information tool (neofetch alternative)
    # 'lf',           # Terminal file manager
    # 'yazi',         # Blazing fast terminal file manager
    # 'sudo',         # Run commands with elevated privileges

    # --- Languages & runtimes ---
    'miniconda3',   # Minimal Python distribution with package manager
    'nodejs',       # JavaScript runtime built on Chrome's V8 engine
    'perl',         # Highly capable, feature-rich programming language
    # 'jq',           # Lightweight JSON processor
    # 'stylua',       # Lua code formatter and linter

    # --- Archive & Packaging ---
    '7zip',         # Archive manager and compressor (Mandatory essentials for Scoop)
    'innounp',      # Inno Setup installer unpacker (Mandatory essentials for Scoop)
    'dark'          # WiX Toolset decompiler for MSI/WiX files (Mandatory essentials for Scoop)
    # '7zip19.00-helper' # 7-Zip 19.00 helper for better compatibility with old Inno Setup installers

    # --- Media processing ---
    # 'ffmpeg',       # Complete multimedia framework for audio/video processing
    # 'imagemagick'   # Image manipulation and conversion toolkit
    # 'chafa',        # Image to text converter for terminal
    # 'scrcpy',       # Android device screen mirroring and control
    # 'yt-dlp',       # Feature-rich video and audio downloader

    # --- Document processing ---
    # 'latex',        # Document typesetting system
    # 'pandoc',       # Universal document converter
    # 'prince',       # HTML to PDF converter
    # 'poppler',      # PDF rendering utilities
    # 'ghostscript',  # PostScript/PDF interpreter and renderer
    # 'graphviz',     # Graph visualization and diagram generation

    # --- Databases ---
    # 'redis',        # In-memory data structure store and database
    # 'mysql',        # Popular open-source relational database management system
    # 'postgresql',   # Advanced open-source relational database

    # --- Networking ---
    # 'ngrok',        # Secure tunnel to localhost for exposing local services to the internet
    # 'aria2',        # Multi-protocol download utility
)})

$global:SCOOP_APPLICATION_EXTRAS = $( if (-not $SCOOP_EXTRAS_FLAG) { @() } else {
@(
    'posh-git',         # PowerShell Git integration with enhanced prompts
    'lazygit',          # Simple terminal UI for git commands

    # 'vscode',           # Lightweight but powerful source code editor

    'altsnap',          # Window management tool for easy resizing/moving
    'powertoys',        # Set of tools for Windows to enhance productivity
    'everything',       # Instant file and folder search engine
    # 'winmerge'          # Visual text file comparison and merging tool
    # 'quicklook',        # Quick file preview tool (like macOS)
    # 'networkmanager',   # Network connection management tool
    # 'registry-finder',  # Search and edit Windows registry entries

    # 'recuva',           # File recovery software
    # 'ccleaner',         # System optimization and cleaning tool
    # 'geekuninstaller',  # Advanced uninstaller for complete software removal
    # 'hwmonitor',        # Hardware monitoring tool for temperature, voltage, and fan speeds
    # 'wiztree',          # Disk usage analyzer and file manager
    # 'fileligtht',       # Disk usage visualization tool showing space consumption
    # 'diskgenius',       # Disk partition management and data recovery tool
    # 'crystaldiskinfo',  # Hard disk health monitoring and S.M.A.R.T. analysis tool
    # 'crystaldiskmark',  # Disk benchmark utility for testing storage performance

    'imageglass',       # Lightweight and versatile image viewer
    # 'vlc',              # Free and open-source media player
    # 'mpv',              # Free and open-source media player

    # 'putty',            # SSH and telnet client for Windows
    # 'moonlight',        # NVIDIA GameStream client for game streaming
    # 'sunshine',         # Self-hosted game streaming server

    'clash-verge-rev'   # Clash Verge Rev: GUI for Clash, a rule-based network tunnel in Go
    # 'bandizip',         # Archive manager with high compression ratio
    # 'cheat-engine',     # Memory scanner and debugger for games
)})

$global:SCOOP_APPLICATION_VERSION = $( if (-not $SCOOP_VERSION_FLAG) { @() } else {
@(
    'tdm-gcc'           # TDM-GCC compiler collection for Windows
)})

$global:SCOOP_APPLICATION = $(if (-not $SCOOP_CHECK_INSTALL) { @() } else {
    $scoop_buckets = (& scoop bucket list).Name
    @() + `
    $(if ($scoop_buckets -contains "main") { $global:SCOOP_APPLICATION_MAIN } else { @() }) + `
    $(if ($scoop_buckets -contains "extras") { $global:SCOOP_APPLICATION_EXTRAS } else { @() }) + `
    $(if ($scoop_buckets -contains "versions") { $global:SCOOP_APPLICATION_VERSION } else { @() })
})

$global:SCOOP_UPDATE_IGNORE = @(
    'postgresql', 'mysql'
)

$global:MODULES = $( if (-not $IMPORT_MODULES) { @{} } else {
@{
    "PSReadLine"         = $(if ($global:PSVERSION -ge "7.2.0") { "latest" } else { "==2.3.4" })
    # "PSFzf"              = $(if ($global:PSVERSION -ge "7.2.0") { "latest" } else { "==2.0.0" })
    # "Get-ChildItemColor" = "latest"
    "WriteAscii"         = "latest"
    # "Terminal-Icons"     = "latest"
    # "posh-git"           = "latest"
}})
