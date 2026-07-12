<#
.SYNOPSIS
    The Scoop-installable part of the work development environment.
.DESCRIPTION
    Read by Install-ScoopApps.ps1 and Test-WorkEnvironment.ps1, which sit next to it,
    so this folder can be copied to another machine and used as-is.

    Optionally, copy this file to config\scoop\catalog.work.ps1 as well:
    start\variables.ps1 picks it up from there, which lets scoop-list annotate work
    apps (scoop-list -Tier work). Nothing here depends on that.

    This catalog is NOT part of $global:SCOOP_APPLICATION, so scoop-check-install
    never touches it. That is deliberate: cmake is version-pinned here, and the
    generic installer does not understand Version — it would upgrade the pin away.

    Same four fields as the other catalogs, plus one:

        Version   optional. When set, exactly this version is installed and the app
                  is held, so 'scoop update' cannot bump it. When absent, the app
                  installs at its current version.

    Comment out an entry to stop installing it.

    Software that Scoop cannot provide (a licensed IDE, vendor-only tools, internal
    tooling) is deliberately absent — see test\work\README.md.
#>

$global:SCOOP_CATALOG_WORK = @(
    # --- Build toolchain ---
    # Pinned: the build scripts are written against 3.28.x.
    @{ Bucket = 'main'; Category = 'Build toolchain';      Name = 'cmake';      Version = '3.28.1'; Description = 'Build system generator — pinned, the team build scripts depend on it' }

    # --- Languages & runtimes ---
    @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'python';     Description = 'Python interpreter and pip' }
    @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'nodejs-lts'; Description = 'Node.js LTS line, as the environment document requires' }
    @{ Bucket = 'main'; Category = 'Languages & runtimes'; Name = 'go';         Description = 'Go toolchain' }

    # --- Version control ---
    @{ Bucket = 'main'; Category = 'Version control';      Name = 'git';        Description = 'Git; configure it with utils\kobayashi\set-git-config.ps1' }

    # --- Development tools ---
    @{ Bucket = 'main'; Category = 'Development tools';    Name = 'cppcheck';   Description = 'Static analysis; the code review tool needs it on PATH' }
    @{ Bucket = 'main'; Category = 'Development tools';    Name = 'llvm';       Description = 'Provides clang-tidy — not mandatory, but strongly recommended' }

    # --- Editors ---
    @{ Bucket = 'extras'; Category = 'Editors';            Name = 'vscode';     Description = 'Visual Studio Code' }
    @{ Bucket = 'extras'; Category = 'Editors';            Name = 'cursor';     Description = 'Cursor'}

    # --- Archive & packaging ---
    @{ Bucket = 'main'; Category = 'Archive & packaging';  Name = '7zip';       Description = 'Archive extraction' }

    # --- Optional in the environment document ---
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'everything';  Description = 'Instant file and folder search' }
    @{ Bucket = 'extras'; Category = 'Desktop & productivity'; Name = 'listary';     Description = 'Launcher and file search' }
    @{ Bucket = 'extras'; Category = 'Development tools';      Name = 'postman';     Description = 'API client' }
    @{ Bucket = 'extras'; Category = 'Networking';             Name = 'switchhosts'; Description = 'Hosts file manager' }
)
