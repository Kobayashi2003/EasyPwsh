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
$global:VIDEeS      = [Environment]::GetFolderPath("MyVideos")
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

$global:APPS_ALIAS = $( if (-not $SET_APPS_ALIAS) { @{} } else {
@{
    'steam'     = 'D:\Steam\Steam.exe'
    'pikpak'    = 'D:\Temp\PikPak\PikPak.exe'

    'wechat'    = 'C:\Program Files (x86)\Tencent\WeChat\WeChat.exe'
}})

$global:SCOOP_APPLICATION_MAIN = $( if (-not $SCOOP_MAIN_FLAG) { @() } else {
@(
    'vim',          # Powerful text editor
    'git',          # Distributed version control system
    '7zip',         # Archive manager and compressor
    'fd',           # Fast and user-friendly alternative to find
    'bat',          # Cat clone with syntax highlighting and Git integration
    'fzf',          # Command-line fuzzy finder
    'yazi',         # Blazing fast terminal file manager
    'zoxide',       # Smart cd command that learns your habits
    'ripgrep',      # Fast text search tool using regex
    'gsudo',        # Sudo implementation for Windows
    'miniconda3',   # Minimal Python distribution with package manager
    'fastfetch'     # Fast system information tool (alternative to neofetch)

    # 'jq',           # Lightweight JSON processor
    # 'ffmpeg',       # Complete multimedia framework for audio/video processing
    # 'latex',        # Document typesetting system
    # 'pandoc',       # Universal document converter
    # 'prince',       # HTML to PDF converter
    # 'scrcpy',       # Android screen mirroring and control
    # 'poppler',      # PDF rendering utilities
    # 'redis',        # In-memory data structure store and database
    # 'postgresql',   # Advanced open-source relational database
    # 'ngrok',        # Secure tunnel to localhost for exposing local services to the internet

    # 'mysql',        # Popular open-source relational database management system
    # 'aria2',        # Multi-protocol download utility
    # 'lf',           # Terminal file manager
    # 'sudo',         # Run commands with elevated privileges
    # 'chafa',        # Image to text converter for terminal
    # 'imagemagick'   # Image manipulation and conversion toolkit
)})

$global:SCOOP_APPLICATION_EXTRAS = $( if (-not $SCOOP_EXTRAS_FLAG) { @() } else {
@(
    'altsnap',          # Window management tool for easy resizing/moving
    'quicklook',        # Quick file preview tool (like macOS)
    'imageglass',       # Lightweight and versatile image viewer
    'everything',       # Instant file and folder search engine
    'bandizip',         # Archive manager with high compression ratio
    'posh-git',         # PowerShell Git integration with enhanced prompts
    'lazygit',          # Simple terminal UI for git commands
    'powertoys'         # Set of tools for Windows to enhance productivity

    # 'cursor',           # AI-powered code editor
    # 'vscode',           # Lightweight but powerful source code editor

    # 'vlc',              # Free and open-source media player
    # 'mpv',              # Free and open-source media player
    # 'winmerge'          # Visual text file comparison and merging tool
    # 'networkmanager',   # Network connection management tool
    # 'registry-finder',  # Search and edit Windows registry entries
    # 'geekuninstaller',  # Advanced uninstaller for complete software removal
    # 'wiztree',          # Disk usage analyzer and file manager
    # 'fileligtht',       # Disk usage visualization tool showing space consumption
    # 'ccleaner',         # System optimization and cleaning tool
    # 'hwmonitor',        # Hardware monitoring tool for temperature, voltage, and fan speeds
    # 'crystaldiskinfo',  # Hard disk health monitoring and S.M.A.R.T. analysis tool
    # 'crystaldiskmark',  # Disk benchmark utility for testing storage performance

    # 'moonlight',        # NVIDIA GameStream client for game streaming
    # 'sunshine',         # Self-hosted game streaming server
    # 'cheat-engine',     # Memory scanner and debugger for games

    # 'recuva',           # File recovery software
    # 'putty',            # SSH and telnet client for Windows
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
