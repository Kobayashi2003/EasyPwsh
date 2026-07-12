<#
.SYNOPSIS
    Example / reference catalog of optional Scoop apps.
.DESCRIPTION
    Not loaded by anything. Copy this to catalog.ps1 (which start\variables.ps1
    dot-sources, and which is gitignored as a per-machine list) and keep the
    entries you actually want.

    Every entry is one hashtable with four fields:

        Bucket       the Scoop bucket it comes from ('scoop bucket list')
        Category     free text, used to group the output of scoop-list
        Name         the Scoop app name ('scoop install <Name>')
        Description  free text, shown by scoop-list

    Uncommented entries are installed when SCOOP_OPTIONAL_FLAG is $true.
    Commented-out entries are never installed — and are invisible at runtime, so
    scoop-list reports them as 'unknown' if you install them by hand.

    Apps that EasyPwsh itself depends on do NOT belong here: they live in
    $global:SCOOP_CATALOG in start\variables.ps1.
#>

$global:SCOOP_CATALOG_OPTIONAL = @(
    # --- main: version control ---
    @{ Bucket = 'main'; Category = 'Version control';      Name = 'gh';               Description = 'GitHub CLI' }

    # --- main: editors ---
    @{ Bucket = 'main'; Category = 'Editors';              Name = 'vim';              Description = 'Modal text editor (apps\init-vim.ps1 links config\vim\_vimrc)' }
    @{ Bucket = 'main'; Category = 'Editors';              Name = 'neovim';           Description = 'Hyperextensible Vim-based text editor' }

    # --- main: shell utilities ---
    # These shape the EasyPwsh shell but are not required: without them the aliases
    # fall back to the built-ins.
    @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'bat';              Description = 'Backs the `cat` alias (apps\init-bat.ps1)' }
    @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'ripgrep';          Description = 'Backs the `grep` alias (apps\init-ripgrep.ps1)' }
    @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'zoxide';           Description = 'Backs the `cd` alias (apps\init-zoxide.ps1)' }
    @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'gsudo';            Description = 'Backs `sudo`; without it start\sudo.ps1 falls back to a PowerShell function' }
    @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'fzf';              Description = 'Command-line fuzzy finder — only used by the PSFzf module' }
    @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'fd';               Description = 'Fast alternative to find — only used by the PSFzf module' }
    @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'jq';               Description = 'Lightweight JSON processor' }
    @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'yazi';             Description = 'Blazing fast terminal file manager (apps\init-yazi.ps1)' }
    # @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'lf';               Description = 'Terminal file manager (apps\init-lf.ps1)' }
    # @{ Bucket = 'main'; Category = 'Shell utilities';      Name = 'fastfetch';        Description = 'Fast system information tool (neofetch alternative)' }

    # --- main: languages & runtimes ---
    @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'nodejs';           Description = "JavaScript runtime built on Chrome's V8 engine" }
    @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'deno';             Description = 'Secure TypeScript/JavaScript runtime' }
    @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'perl';             Description = 'Highly capable, feature-rich programming language' }

    # --- main: development tools ---
    @{ Bucket = 'main'; Category = 'Development tools';    Name = 'android-clt';      Description = 'Android SDK command-line tools' }
    @{ Bucket = 'main'; Category = 'Development tools';    Name = 'stylua';           Description = 'Lua code formatter and linter' }

    # --- main: media processing ---
    @{ Bucket = 'main'; Category = 'Media processing';     Name = 'ffmpeg';           Description = 'Complete multimedia framework (apps\init-ffmpeg.ps1)' }
    @{ Bucket = 'main'; Category = 'Media processing';     Name = 'imagemagick';      Description = 'Image manipulation and conversion toolkit' }
    @{ Bucket = 'main'; Category = 'Media processing';     Name = 'chafa';            Description = 'Image to text converter for the terminal (apps\init-chafa.ps1)' }
    @{ Bucket = 'main'; Category = 'Media processing';     Name = 'yt-dlp';           Description = 'Feature-rich video and audio downloader (apps\init-yt-dlp.ps1)' }
    @{ Bucket = 'main'; Category = 'Media processing';     Name = 'bbdown';           Description = 'Bilibili video downloader' }
    @{ Bucket = 'main'; Category = 'Media processing';     Name = 'scrcpy';           Description = 'Android device screen mirroring and control' }

    # --- main: document processing ---
    @{ Bucket = 'main'; Category = 'Document processing';  Name = 'latex';            Description = 'Document typesetting system' }
    @{ Bucket = 'main'; Category = 'Document processing';  Name = 'pandoc';           Description = 'Universal document converter' }
    @{ Bucket = 'main'; Category = 'Document processing';  Name = 'prince';           Description = 'HTML to PDF converter' }
    @{ Bucket = 'main'; Category = 'Document processing';  Name = 'poppler';          Description = 'PDF rendering utilities' }
    @{ Bucket = 'main'; Category = 'Document processing';  Name = 'ghostscript';      Description = 'PostScript/PDF interpreter and renderer' }
    @{ Bucket = 'main'; Category = 'Document processing';  Name = 'graphviz';         Description = 'Graph visualization and diagram generation' }

    # --- main: databases ---
    @{ Bucket = 'main'; Category = 'Databases';            Name = 'postgresql';       Description = 'Advanced open-source relational database' }
    @{ Bucket = 'main'; Category = 'Databases';            Name = 'redis';            Description = 'In-memory data structure store and database' }
    # @{ Bucket = 'main'; Category = 'Databases';            Name = 'mysql';            Description = 'Popular open-source relational database' }

    # --- main: networking ---
    @{ Bucket = 'main'; Category = 'Networking';           Name = 'caddy';            Description = 'Web server with automatic HTTPS' }
    @{ Bucket = 'main'; Category = 'Networking';           Name = 'rclone';           Description = 'Sync files to and from cloud storage' }
    @{ Bucket = 'main'; Category = 'Networking';           Name = 'alist';            Description = 'File list program supporting many storage providers' }
    @{ Bucket = 'main'; Category = 'Networking';           Name = 'subconverter';     Description = 'Proxy subscription format converter' }
    # @{ Bucket = 'main'; Category = 'Networking';           Name = 'aria2';            Description = 'Multi-protocol download utility — Scoop uses it for parallel downloads' }
    # @{ Bucket = 'main'; Category = 'Networking';           Name = 'ngrok';            Description = 'Secure tunnel exposing a local service to the internet' }

    # --- extras: git tooling ---
    @{ Bucket = 'extras'; Category = 'Git tooling';            Name = 'posh-git';        Description = 'PowerShell Git integration with enhanced prompts' }
    @{ Bucket = 'extras'; Category = 'Git tooling';            Name = 'lazygit';         Description = 'Simple terminal UI for git commands' }

    # --- extras: editors ---
    # @{ Bucket = 'extras'; Category = 'Editors';                Name = 'vscode';          Description = 'Lightweight but powerful source code editor' }

    # --- extras: languages & runtimes ---
    @{ Bucket = 'extras'; Category = 'Languages & runtimes';   Name = 'miniconda3';      Description = 'Minimal Python distribution with package manager (apps\init-conda.ps1)' }
    @{ Bucket = 'extras'; Category = 'Languages & runtimes';   Name = 'flutter';         Description = 'UI toolkit and SDK for cross-platform apps' }

    # --- extras: development tools ---
    @{ Bucket = 'extras'; Category = 'Development tools';      Name = 'hxd';             Description = 'Hex editor and disk editor' }

    # --- extras: desktop & productivity ---
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'altsnap';         Description = 'Window management tool for easy resizing/moving' }
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'powertoys';       Description = 'Set of tools for Windows to enhance productivity' }
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'everything';      Description = 'Instant file and folder search engine' }
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'quicklook';       Description = 'Quick file preview — bound to Ctrl+Space in modules\module.PSReadLine.ps1' }
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'winmerge';        Description = 'Visual text file comparison and merging tool' }
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'registry-finder'; Description = 'Search and edit Windows registry entries' }
    # @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'networkmanager';  Description = 'Network connection management tool' }

    # --- extras: system maintenance ---
    @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'sysinternals';    Description = 'Sysinternals troubleshooting suite' }
    @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'ccleaner';        Description = 'System optimization and cleaning tool' }
    @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'geekuninstaller'; Description = 'Advanced uninstaller for complete software removal' }
    @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'recuva';          Description = 'File recovery software' }
    @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'hwmonitor';       Description = 'Hardware monitoring — temperature, voltage, fan speed' }
    @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'wiztree';         Description = 'Disk usage analyzer and file manager' }
    @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'diskgenius';      Description = 'Disk partition management and data recovery' }
    @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'crystaldiskinfo'; Description = 'Disk health monitoring and S.M.A.R.T. analysis' }
    @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'crystaldiskmark'; Description = 'Disk benchmark utility' }
    # @{ Bucket = 'extras'; Category = 'System maintenance';     Name = 'filelight';       Description = 'Disk usage visualization' }

    # --- extras: archive & packaging ---
    @{ Bucket = 'extras'; Category = 'Archive & packaging';    Name = 'ultraiso';        Description = 'ISO image creation and editing' }
    # @{ Bucket = 'extras'; Category = 'Archive & packaging';    Name = 'bandizip';        Description = 'Archive manager with high compression ratio' }

    # --- extras: media ---
    @{ Bucket = 'extras'; Category = 'Media';                  Name = 'imageglass';      Description = 'Lightweight and versatile image viewer' }
    # @{ Bucket = 'extras'; Category = 'Media';                  Name = 'vlc';             Description = 'Free and open-source media player' }
    # @{ Bucket = 'extras'; Category = 'Media';                  Name = 'mpv';             Description = 'Free and open-source media player (apps\init-mpv.ps1)' }

    # --- extras: remote & streaming ---
    @{ Bucket = 'extras'; Category = 'Remote & streaming';     Name = 'rustdesk';        Description = 'Open-source remote desktop' }
    @{ Bucket = 'extras'; Category = 'Remote & streaming';     Name = 'sunshine';        Description = 'Self-hosted game streaming server' }
    # @{ Bucket = 'extras'; Category = 'Remote & streaming';     Name = 'moonlight';       Description = 'NVIDIA GameStream client for game streaming' }
    # @{ Bucket = 'extras'; Category = 'Remote & streaming';     Name = 'putty';           Description = 'SSH and telnet client for Windows' }

    # --- extras: networking ---
    @{ Bucket = 'extras'; Category = 'Networking';             Name = 'clash-verge-rev'; Description = 'GUI for Clash, a rule-based network tunnel in Go' }
    @{ Bucket = 'extras'; Category = 'Networking';             Name = 'qbittorrent';     Description = 'BitTorrent client' }
    @{ Bucket = 'extras'; Category = 'Networking';             Name = 'mullvad-browser'; Description = 'Privacy-focused web browser' }

    # --- java ---
    @{ Bucket = 'java'; Category = 'Languages & runtimes';     Name = 'temurin17-jdk';   Description = 'Eclipse Temurin JDK 17' }

    # --- versions ---
    @{ Bucket = 'versions'; Category = 'Languages & runtimes'; Name = 'nodejs22';        Description = 'Node.js 22 LTS, alongside the current nodejs' }
    # @{ Bucket = 'versions'; Category = 'Toolchains';           Name = 'tdm-gcc';         Description = 'TDM-GCC compiler collection for Windows' }
)
