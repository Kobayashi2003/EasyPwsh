<#
.SYNOPSIS
    Set up the development work environment on a machine that already has Scoop
    and EasyPwsh.

.DESCRIPTION
    Installs the toolchain from the team's environment document, using only Scoop
    and official upstream sources. The intranet file server is never used, so this
    works from anywhere.

    Version policy:
      - CMake and Python are pinned, because the build scripts depend on them:
          cmake     3.28.1     exact pin, then held
          python    3.10.x     via the versions/python310 manifest
      - Everything else installs at its current version.

    Behaviour:
      - Each step is one Install-* function, gated on a keypress.
      - Already-satisfied steps are detected and skipped, so re-running is safe.
      - Scoop apps are never uninstalled. A pinned version is installed
        side-by-side and 'current' is switched to it, so <scoop>\persist\<app>
        (your app configuration) survives.
      - Pinned apps are held, otherwise the next 'scoop update' — including the one
        EasyPwsh's scoop-check-update runs — would silently upgrade them again.
      - A preflight pass checks every pinned download before anything is installed.
      - A batch check runs at the end and verifies every tool in one pass.

.PARAMETER PipIndexUrl
    Package index used to install the internal repo tooling (krepo). It is not
    stored in this script; pass it here, or the krepo step will ask for it.
    Reachable only from the corporate network.

.PARAMETER Only
    Only run the steps whose Key matches (e.g. -Only cmake,python).

.PARAMETER SkipOptional
    Skip the steps the team document marks optional.

.PARAMETER DryRun
    Show what each step would do, without installing anything.

.PARAMETER CheckOnly
    Skip installation and just run the batch check.

.PARAMETER NoPreflight
    Skip the URL reachability check.

.EXAMPLE
    .\Install-WorkEnvironment.ps1
    .\Install-WorkEnvironment.ps1 -Only cmake,python
    .\Install-WorkEnvironment.ps1 -CheckOnly
    .\Install-WorkEnvironment.ps1 -PipIndexUrl https://example.internal/pypi/dev/
#>

[CmdletBinding()]
param(
    [string]   $PipIndexUrl,
    [string[]] $Only,
    [switch]   $SkipOptional,
    [switch]   $DryRun,
    [switch]   $CheckOnly,
    [switch]   $NoPreflight
)

$ErrorActionPreference = 'Stop'

# ─── Pinned versions ──────────────────────────────────────────────────────────
# The only two versions the team document actually constrains.
$CMAKE_VERSION = '3.28.1'
$PYTHON_APP    = 'python310'   # versions bucket, tracks the 3.10.x line
$PYTHON_SERIES = '3.10'

$REQUIRED_BUCKETS = @('main', 'extras', 'versions')

# ─── Output helpers ───────────────────────────────────────────────────────────

function Write-Title($Text) {
    Write-Host ''
    Write-Host ('─' * 78) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('─' * 78) -ForegroundColor DarkCyan
}
function Write-Ok   ($Text) { Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Skip ($Text) { Write-Host "  [skip] $Text" -ForegroundColor DarkGray }
function Write-Info ($Text) { Write-Host "  [info] $Text" -ForegroundColor Gray }
function Write-Act  ($Text) { Write-Host "  [do]   $Text" -ForegroundColor Yellow }
function Write-Fail ($Text) { Write-Host "  [fail] $Text" -ForegroundColor Red }

# ─── Scoop helpers ────────────────────────────────────────────────────────────

function Get-ScoopVersion {
    <#
    .SYNOPSIS
        The installed version of a Scoop app, or $null when it is not installed.
    #>
    param([Parameter(Mandatory)] [string] $App)

    $current = Join-Path $env:SCOOP "apps\$App\current"
    if (-not (Test-Path $current)) { return $null }

    $manifest = Join-Path $current 'manifest.json'
    if (Test-Path $manifest) {
        try { return (Get-Content $manifest -Raw | ConvertFrom-Json).version } catch { }
    }
    return (Get-Item $current).Target | Split-Path -Leaf
}

function Install-ScoopApp {
    <#
    .SYNOPSIS
        Install a Scoop app, optionally pinned to an exact version.
    .DESCRIPTION
        With -Version: installs that version alongside whatever is already there,
        points 'current' at it, and holds the app. Never uninstalls, so persisted
        configuration under <scoop>\persist survives.
        Without -Version: installs only if missing; an existing install is left
        alone, because the team document does not constrain its version.
    #>
    param(
        [Parameter(Mandatory)] [string] $App,
        [string] $Version
    )

    $installed = Get-ScoopVersion -App $App

    if (-not $Version) {
        if ($installed) {
            Write-Skip "$App $installed is already installed (version is unconstrained)"
            return 'Skipped'
        }
        Write-Act "scoop install $App"
        if ($DryRun) { return 'DryRun' }
        & scoop install $App
        if ($LASTEXITCODE -ne 0) { throw "scoop install $App failed" }
        return 'Installed'
    }

    if ($installed -eq $Version) {
        Write-Skip "$App is already at the pinned version $Version"
        & scoop hold $App *>$null
        return 'Skipped'
    }

    if ($installed) {
        Write-Info "$App $installed is installed, but $Version is required"
        # A hold also blocks 'scoop install <app>@<version>', so release it first.
        & scoop unhold $App *>$null
    }

    if (Test-Path (Join-Path $env:SCOOP "apps\$App\$Version")) {
        Write-Act "scoop reset $App@$Version   (already on disk, no download)"
        if ($DryRun) { return 'DryRun' }
        & scoop reset "$App@$Version"
    } else {
        Write-Act "scoop install $App@$Version"
        if ($DryRun) { return 'DryRun' }
        & scoop install "$App@$Version"
    }
    if ($LASTEXITCODE -ne 0) { throw "installing $App@$Version failed" }

    # Without this, the next 'scoop update *' pulls the pin straight back up.
    & scoop hold $App *>$null
    Write-Info "$App is held, so 'scoop update' will not bump it"

    return 'Installed'
}

function Confirm-Step {
    <#
    .OUTPUTS
        'run', 'skip', or 'quit'
    #>
    param([string] $Prompt = 'Press ENTER to install, [s] to skip, [q] to quit')

    while ($true) {
        Write-Host ''
        Write-Host "  $Prompt : " -ForegroundColor Magenta -NoNewline
        switch ((Read-Host).Trim().ToLower()) {
            ''  { return 'run' }
            's' { return 'skip' }
            'q' { return 'quit' }
            default { Write-Host '  Unrecognized input.' -ForegroundColor DarkYellow }
        }
    }
}

function Get-InstallDirectory {
    <#
    .SYNOPSIS
        Ask where to put software Scoop cannot manage.
    #>
    param([string] $App, [string] $Default)

    Write-Host ''
    Write-Host "  $App is not available through Scoop, so it needs an install location." -ForegroundColor Yellow
    $dir = Read-Host "  Install directory (ENTER for $Default)"
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = $Default }
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    return $dir
}

function Save-Download {
    <#
    .SYNOPSIS
        Download to a cache directory, reusing the file when it is already complete.
    #>
    param([string] $Url, [string] $FileName)

    $cache = Join-Path $env:TEMP 'work-env-setup'
    if (-not (Test-Path $cache)) { New-Item -ItemType Directory -Force -Path $cache | Out-Null }
    $target = Join-Path $cache $FileName

    $expected = $null
    try {
        $head = Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 -TimeoutSec 30
        $expected = [long]($head.Headers['Content-Length'] | Select-Object -First 1)
    } catch { }

    if ((Test-Path $target) -and $expected -and ((Get-Item $target).Length -eq $expected)) {
        Write-Info "reusing cached download: $target"
        return $target
    }

    Write-Act "downloading $FileName"
    Invoke-WebRequest -Uri $Url -OutFile $target -TimeoutSec 600
    return $target
}

function Test-Url {
    param([string] $Url)
    try {
        Invoke-WebRequest -Uri $Url -Method Head -MaximumRedirection 5 -TimeoutSec 20 | Out-Null
        return $true
    } catch {
        return $false
    }
}

# ─── One function per piece of software ───────────────────────────────────────

function Install-CMake {
    # The team document's prose says 3.16.0 but its own download link is 3.28.1;
    # the link wins.
    Install-ScoopApp -App 'cmake' -Version $CMAKE_VERSION
}

function Install-Python {
    # The document asks for 3.10.0. versions/python310 tracks the 3.10.x line and is
    # a maintained manifest, unlike a manifest synthesized for python@3.10.0.
    $result = Install-ScoopApp -App $PYTHON_APP
    if ($DryRun) { return $result }

    # Any other Python — the 'python' app, miniconda3, anaconda — also ships a
    # 'python' shim, and whichever was installed last owns it. Claim it back.
    Write-Act "scoop reset $PYTHON_APP   (claim the python/pip shims)"
    & scoop reset $PYTHON_APP

    # A conda base environment prepends itself to PATH from the shell profile, which
    # wins over the shim no matter what Scoop does. Detect that rather than let the
    # user discover it when a build picks the wrong interpreter.
    $env:PATH = "$env:SCOOP\shims;$env:PATH"
    $source = (Get-Command python -ErrorAction SilentlyContinue).Source
    $actual = Get-CommandVersion 'python' @('--version')

    if ($actual -notmatch "^Python\s+$([regex]::Escape($PYTHON_SERIES))\.") {
        Write-Fail "'python' still resolves to $actual"
        Write-Info "it comes from: $source"
        Write-Info "another Python is shadowing $PYTHON_APP on PATH — most often a conda base"
        Write-Info "environment activated by your shell profile. Deactivate it, or put"
        Write-Info "$env:SCOOP\shims ahead of it, then re-check with -CheckOnly."
    } else {
        Write-Ok "python resolves to $actual"
    }
    return $result
}

function Install-Git {
    $result = Install-ScoopApp -App 'git'

    Write-Host ''
    Write-Info 'Git configuration required by the team document:'
    $name  = Read-Host '  git user.name  (ENTER to leave unchanged)'
    $email = Read-Host '  git user.email (ENTER to leave unchanged)'

    if (-not $DryRun) {
        if ($name)  { & git config --global user.name  $name }
        if ($email) { & git config --global user.email $email }
        # The document requires cross-platform newline conversion to be off.
        & git config --global core.autocrlf false
        Write-Ok 'core.autocrlf = false'
    }

    $ssh_key = Join-Path $env:USERPROFILE '.ssh\id_rsa.pub'
    if (Test-Path $ssh_key) {
        Write-Ok "SSH key already exists: $ssh_key"
    } else {
        Write-Info 'No SSH key found. Create one with:  ssh-keygen -t rsa'
        Write-Info 'Then add ~/.ssh/id_rsa.pub to your Git server profile.'
    }
    return $result
}

function Install-SevenZip {
    Install-ScoopApp -App '7zip'
}

function Install-NodeJs {
    # The document asks for the LTS line, so use nodejs-lts rather than nodejs,
    # which tracks Current.
    Install-ScoopApp -App 'nodejs-lts'
}

function Install-Go {
    Install-ScoopApp -App 'go'
}

function Install-Cppcheck {
    $result = Install-ScoopApp -App 'cppcheck'
    # The document warns that cppcheck must be on PATH or 'krepo cr' cannot produce
    # its report. Scoop's shim directory is already on PATH.
    Write-Info "Scoop shims are on PATH, so the cppcheck PATH requirement is satisfied"
    return $result
}

function Install-VSCode {
    Install-ScoopApp -App 'vscode'
}

function Install-Krepo {
    # The repo tooling lives on an internal package index that is only reachable from
    # the corporate network. The URL is deliberately not baked into this script.
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Fail 'python is not on PATH; run the python step first'
        return 'Failed'
    }

    $index = $PipIndexUrl
    if (-not $index) {
        Write-Info 'The repo tooling comes from an internal package index.'
        $index = Read-Host '  Package index URL (ENTER to skip this step)'
    }
    if (-not $index) {
        Write-Skip 'no package index given'
        return 'Skipped'
    }

    if (-not (Test-Url $index)) {
        Write-Fail "cannot reach $index — connect to the corporate network, then re-run with -Only krepo"
        return 'Failed'
    }

    Write-Act "pip install kso-repo-tool + krepo-v2 from $index"
    if ($DryRun) { return 'DryRun' }

    & python -m pip install --upgrade kso-repo-tool -i $index --no-cache --user
    & python -m pip install --upgrade krepo-v2 -i $index --no-cache

    # The document has you locate the Scripts directory by hand; derive it instead.
    $scripts = & python -c "import sysconfig; print(sysconfig.get_path('scripts', 'nt_user'))" 2>$null
    if ($scripts -and (Test-Path (Join-Path $scripts 'krepo.exe'))) {
        $user_path = [Environment]::GetEnvironmentVariable('PATH', 'User')
        if ($user_path -notlike "*$scripts*") {
            [Environment]::SetEnvironmentVariable('PATH', "$scripts;$user_path", 'User')
            Write-Ok "added $scripts to your user PATH"
        } else {
            Write-Ok "$scripts is already on PATH"
        }
        $env:PATH = "$scripts;$env:PATH"
    } else {
        Write-Info 'could not locate krepo.exe; find it with:  pip show kso-repo-tool'
    }
    return 'Installed'
}

function Install-VisualStudio {
    # Licensed, and distributed as a multi-gigabyte ISO. The official bootstrapper can
    # preselect the workloads, but it always installs the newest 16.11.x, so the
    # document's exact 16.11.37 cannot be reproduced.
    Write-Info 'Visual Studio cannot be installed unattended from a public source.'
    Write-Info 'If VS 2019 is already installed, use Visual Studio Installer -> Modify.'
    Write-Host ''
    Write-Host '  Components required by the team document:' -ForegroundColor Yellow
    Write-Host '    - Desktop development with C++         Microsoft.VisualStudio.Workload.NativeDesktop'
    Write-Host '    - Visual Studio extension development  Microsoft.VisualStudio.Workload.VisualStudioExtension'
    Write-Host '    - MFC                                  Microsoft.VisualStudio.Component.VC.ATLMFC'
    Write-Host '    - C++ 2019 Redistributable MSM         Microsoft.VisualStudio.Component.VC.Redist.MSM'
    Write-Host '    - Windows 10 SDK 18362                 Microsoft.VisualStudio.Component.Windows10SDK.18362'
    Write-Host '    - MSVC v142 toolset 14.29              Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64'
    Write-Host '    - English language pack (third-party libraries need it to build)'
    Write-Host ''
    Write-Host '  The bootstrapper can preselect all of it:' -ForegroundColor Yellow
    Write-Host '    vs_professional.exe --addProductLang En-us --includeRecommended `' -ForegroundColor DarkGray
    Write-Host '      --add Microsoft.VisualStudio.Workload.NativeDesktop `' -ForegroundColor DarkGray
    Write-Host '      --add Microsoft.VisualStudio.Workload.VisualStudioExtension `' -ForegroundColor DarkGray
    Write-Host '      --add Microsoft.VisualStudio.Component.VC.ATLMFC `' -ForegroundColor DarkGray
    Write-Host '      --add Microsoft.VisualStudio.Component.VC.Redist.MSM `' -ForegroundColor DarkGray
    Write-Host '      --add Microsoft.VisualStudio.Component.Windows10SDK.18362 `' -ForegroundColor DarkGray
    Write-Host '      --add Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64' -ForegroundColor DarkGray
    Write-Host ''

    if ((Read-Host '  Download the VS 2019 bootstrapper now? (y/N)') -notin 'y', 'Y') { return 'Skipped' }
    if ($DryRun) { return 'DryRun' }

    $dir = Get-InstallDirectory -App 'Visual Studio bootstrapper' -Default (Join-Path $env:USERPROFILE 'Downloads')
    $exe = Save-Download -Url 'https://aka.ms/vs/16/release/vs_professional.exe' -FileName 'vs_professional.exe'
    Copy-Item $exe $dir -Force
    Write-Ok "bootstrapper saved to $dir — run it with the arguments above"
    return 'Manual'
}

function Install-Pixso {
    # The vendor serves its download link from JavaScript and keeps no archive of old
    # builds, so the pinned 2.2.8 is not obtainable.
    Write-Info 'Pixso has no scriptable download and no public archive of old versions.'
    Write-Info 'Opening the official download page; install the current version.'
    if (-not $DryRun) { Start-Process 'https://pixso.cn/download/' }
    return 'Manual'
}

function Install-ClangTidy {
    Install-ScoopApp -App 'llvm'
}

function Install-Everything {
    Install-ScoopApp -App 'everything'
}

function Install-Listary {
    Install-ScoopApp -App 'listary'
}

function Install-Postman {
    # The document pins 11.2.0.0, but the vendor CDN only serves the current release
    # (that build now 404s) and the version is not constrained.
    Install-ScoopApp -App 'postman'
}

function Install-SwitchHosts {
    Install-ScoopApp -App 'switchhosts'
}

function Install-CcSwitch {
    # Not in any Scoop bucket, so this is a plain MSI install.
    $api = 'https://api.github.com/repos/farion1231/cc-switch/releases/latest'
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'work-env-setup' } -TimeoutSec 30
    $asset = $release.assets | Where-Object { $_.name -like '*Windows.msi' } | Select-Object -First 1
    if (-not $asset) {
        Write-Fail 'no Windows .msi asset in the latest CC-Switch release'
        return 'Failed'
    }

    Write-Info "latest release: $($release.tag_name) ($($asset.name))"
    if ($DryRun) { return 'DryRun' }

    $msi = Save-Download -Url $asset.browser_download_url -FileName $asset.name
    $dir = Get-InstallDirectory -App 'CC-Switch' -Default 'C:\Program Files\CC-Switch'

    Write-Act "msiexec /i $($asset.name) INSTALLDIR=`"$dir`""
    $proc = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qb', "INSTALLDIR=`"$dir`"") -Wait -PassThru
    if ($proc.ExitCode -ne 0) { throw "msiexec exited with $($proc.ExitCode)" }
    return 'Installed'
}

# ─── The steps ────────────────────────────────────────────────────────────────

$Steps = @(
    @{ Key = 'cmake';       Title = "CMake $CMAKE_VERSION (pinned)";                    Required = $true;  Install = { Install-CMake }
       Url = "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-windows-x86_64.zip" }
    @{ Key = 'python';      Title = "Python $PYTHON_SERIES.x (pinned series)";          Required = $true;  Install = { Install-Python }
       Url = 'https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe' }
    @{ Key = 'git';         Title = 'Git';                                              Required = $true;  Install = { Install-Git } }
    @{ Key = '7zip';        Title = '7-Zip';                                            Required = $true;  Install = { Install-SevenZip } }
    @{ Key = 'nodejs';      Title = 'Node.js (LTS)';                                    Required = $true;  Install = { Install-NodeJs } }
    @{ Key = 'go';          Title = 'Go';                                               Required = $true;  Install = { Install-Go } }
    @{ Key = 'cppcheck';    Title = 'Cppcheck (required by krepo cr)';                  Required = $true;  Install = { Install-Cppcheck } }
    @{ Key = 'vscode';      Title = 'Visual Studio Code';                               Required = $true;  Install = { Install-VSCode } }
    @{ Key = 'krepo';       Title = 'Krepo (kso-repo-tool + krepo-v2)';                 Required = $true;  Install = { Install-Krepo } }
    @{ Key = 'vs2019';      Title = 'Visual Studio 2019 Professional 16.11 (manual)';   Required = $true;  Install = { Install-VisualStudio } }
    @{ Key = 'pixso';       Title = 'Pixso (manual)';                                   Required = $true;  Install = { Install-Pixso } }
    @{ Key = 'clang-tidy';  Title = 'Clang-Tidy (LLVM) — strongly recommended';         Required = $false; Install = { Install-ClangTidy } }
    @{ Key = 'everything';  Title = 'Everything';                                       Required = $false; Install = { Install-Everything } }
    @{ Key = 'listary';     Title = 'Listary';                                          Required = $false; Install = { Install-Listary } }
    @{ Key = 'postman';     Title = 'Postman';                                          Required = $false; Install = { Install-Postman } }
    @{ Key = 'switchhosts'; Title = 'SwitchHosts';                                      Required = $false; Install = { Install-SwitchHosts } }
    @{ Key = 'cc-switch';   Title = 'CC-Switch';                                        Required = $false; Install = { Install-CcSwitch }
       Url = 'https://github.com/farion1231/cc-switch/releases/latest' }
)

# ─── Batch check ──────────────────────────────────────────────────────────────

function Get-CommandVersion {
    <#
    .SYNOPSIS
        Run a tool's version command and return its first line, or $null when the
        tool is not on PATH.
    #>
    param([string] $Command, [string[]] $VersionArgs)

    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) { return $null }
    try {
        $out = & $Command @VersionArgs 2>&1 | Out-String
        return (($out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
    } catch {
        return $null
    }
}

function Test-WorkEnvironment {
    <#
    .SYNOPSIS
        Verify every tool in one pass: is it there, and does the pinned version match.
    #>
    Write-Title 'Batch check'

    # A fresh shim is not visible to this process until PATH is refreshed.
    $env:PATH = "$env:SCOOP\shims;" + [Environment]::GetEnvironmentVariable('PATH', 'User') + ';' +
                                      [Environment]::GetEnvironmentVariable('PATH', 'Machine')

    $rows = @()

    function New-Row($Name, $Required, $Status, $Detail) {
        [PSCustomObject]@{ Tool = $Name; Required = $Required; Status = $Status; Detail = $Detail }
    }

    # --- pinned: the version has to match, not just be present ---
    $cmake = Get-CommandVersion 'cmake' @('--version')
    $rows += if (-not $cmake) {
        New-Row 'cmake' $true 'MISSING' 'not on PATH'
    } elseif ($cmake -match [regex]::Escape($CMAKE_VERSION)) {
        New-Row 'cmake' $true 'OK' $cmake
    } else {
        New-Row 'cmake' $true 'WRONG VERSION' "$cmake (expected $CMAKE_VERSION)"
    }

    $python = Get-CommandVersion 'python' @('--version')
    $python_source = (Get-Command python -ErrorAction SilentlyContinue).Source
    $rows += if (-not $python) {
        New-Row 'python' $true 'MISSING' 'not on PATH'
    } elseif ($python -match "^Python\s+$([regex]::Escape($PYTHON_SERIES))\.") {
        New-Row 'python' $true 'OK' $python
    } else {
        # Name the interpreter that won, so a shadowing conda base is obvious.
        New-Row 'python' $true 'WRONG VERSION' "$python (expected $PYTHON_SERIES.x) from $python_source"
    }

    # --- command line tools: presence is enough ---
    $cli = [ordered]@{
        'git'        = @{ Cmd = 'git';        Args = @('--version');    Required = $true  }
        '7zip'       = @{ Cmd = '7z';         Args = @();               Required = $true  }
        'node'       = @{ Cmd = 'node';       Args = @('--version');    Required = $true  }
        'npm'        = @{ Cmd = 'npm';        Args = @('--version');    Required = $true  }
        'go'         = @{ Cmd = 'go';         Args = @('version');      Required = $true  }
        'cppcheck'   = @{ Cmd = 'cppcheck';   Args = @('--version');    Required = $true  }
        'vscode'     = @{ Cmd = 'code';       Args = @('--version');    Required = $true  }
        'krepo'      = @{ Cmd = 'krepo';      Args = @('-v');           Required = $true  }
        'pip'        = @{ Cmd = 'pip';        Args = @('--version');    Required = $true  }
        'clang-tidy' = @{ Cmd = 'clang-tidy'; Args = @('--version');    Required = $false }
    }
    foreach ($name in $cli.Keys) {
        $spec = $cli[$name]
        $version = Get-CommandVersion $spec.Cmd $spec.Args
        $rows += if ($version) {
            New-Row $name $spec.Required 'OK' $version
        } else {
            New-Row $name $spec.Required 'MISSING' "'$($spec.Cmd)' not on PATH"
        }
    }

    # --- git settings the document requires ---
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $autocrlf = (& git config --global core.autocrlf) 2>$null
        $rows += if ("$autocrlf".Trim() -eq 'false') {
            New-Row 'git core.autocrlf' $true 'OK' 'false'
        } else {
            New-Row 'git core.autocrlf' $true 'WRONG' "'$autocrlf' (must be false)"
        }

        $user  = (& git config --global user.name)  2>$null
        $email = (& git config --global user.email) 2>$null
        $rows += if ($user -and $email) {
            New-Row 'git identity' $true 'OK' "$user <$email>"
        } else {
            New-Row 'git identity' $true 'MISSING' 'user.name / user.email not set'
        }

        $rows += if (Test-Path (Join-Path $env:USERPROFILE '.ssh\id_rsa.pub')) {
            New-Row 'git ssh key' $true 'OK' '~/.ssh/id_rsa.pub'
        } else {
            New-Row 'git ssh key' $true 'MISSING' 'run ssh-keygen -t rsa'
        }
    }

    # --- GUI apps: no CLI to interrogate, so ask Scoop ---
    $gui = [ordered]@{
        'everything'  = $false
        'listary'     = $false
        'postman'     = $false
        'switchhosts' = $false
    }
    foreach ($app in $gui.Keys) {
        $version = Get-ScoopVersion -App $app
        $rows += if ($version) {
            New-Row $app $gui[$app] 'OK' "scoop: $version"
        } else {
            New-Row $app $gui[$app] 'MISSING' 'not installed'
        }
    }

    # --- things Scoop does not manage ---
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $rows += if (Test-Path $vswhere) {
        $vs = & $vswhere -version '[16.0,17.0)' -property catalog_productDisplayVersion 2>$null | Select-Object -First 1
        if ($vs) { New-Row 'visual studio 2019' $true 'OK' $vs }
        else     { New-Row 'visual studio 2019' $true 'MISSING' 'no 16.x installation found' }
    } else {
        New-Row 'visual studio 2019' $true 'UNKNOWN' 'vswhere.exe not found'
    }

    $ccswitch = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
        ForEach-Object { $_.GetValue('DisplayName') } | Where-Object { $_ -like '*CC*Switch*' } | Select-Object -First 1
    $rows += if ($ccswitch) { New-Row 'cc-switch' $false 'OK' $ccswitch }
             else           { New-Row 'cc-switch' $false 'MISSING' 'not installed' }

    # --- report ---
    Write-Host ''
    foreach ($r in $rows) {
        $color = switch ($r.Status) {
            'OK'      { 'Green' }
            'UNKNOWN' { 'DarkYellow' }
            'MISSING' { if ($r.Required) { 'Red' } else { 'DarkGray' } }
            default   { 'Red' }
        }
        $mark = if ($r.Status -eq 'OK') { '+' } elseif (-not $r.Required) { '-' } else { 'x' }
        Write-Host ('  {0} {1,-20} {2,-14} {3}' -f $mark, $r.Tool, $r.Status, $r.Detail) -ForegroundColor $color
    }

    $broken = @($rows | Where-Object { $_.Required -and $_.Status -ne 'OK' })
    Write-Host ''
    if ($broken) {
        Write-Fail "$($broken.Count) required item(s) not satisfied: $(($broken.Tool) -join ', ')"
        Write-Info 'Re-run the matching step, e.g.:  .\Install-WorkEnvironment.ps1 -Only cmake'
        Write-Info 'If a tool was just installed, open a new shell first — PATH may be stale.'
    } else {
        Write-Ok 'Every required tool is present and correctly versioned.'
    }

    return $rows
}

# ─── Entry point ──────────────────────────────────────────────────────────────

Write-Title 'Work environment setup'
Write-Host "  Scoop root : $env:SCOOP"
Write-Host "  Pinned     : cmake $CMAKE_VERSION, python $PYTHON_SERIES.x ($PYTHON_APP)"
Write-Host "  Unpinned   : everything else installs at its current version"
if ($DryRun) { Write-Host '  DRY RUN — nothing will be installed' -ForegroundColor Yellow }

if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Fail 'Scoop is not installed. Install Scoop first (EasyPwsh will offer to do it).'
    return
}

# Elevation breaks Scoop: shims and apps end up owned by the admin account.
if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole] 'Administrator')) {
    Write-Fail 'This shell is elevated. Run the script from a normal, non-admin shell.'
    return
}

if ($CheckOnly) {
    Test-WorkEnvironment | Out-Null
    return
}

Write-Title 'Preflight'

$buckets = @(& scoop bucket list).Name
foreach ($bucket in $REQUIRED_BUCKETS) {
    if ($buckets -contains $bucket) {
        Write-Ok "bucket $bucket"
    } else {
        Write-Act "scoop bucket add $bucket"
        if (-not $DryRun) { & scoop bucket add $bucket }
    }
}

$steps_to_run = $Steps |
    Where-Object { -not $Only -or ($Only -contains $_.Key) } |
    Where-Object { -not ($SkipOptional -and -not $_.Required) }

if (-not $steps_to_run) {
    Write-Fail 'No steps selected.'
    return
}

if (-not $NoPreflight) {
    Write-Host ''
    Write-Info 'Checking that the pinned downloads still exist upstream...'
    $dead = @()
    foreach ($step in ($steps_to_run | Where-Object { $_.Url })) {
        if (Test-Url $step.Url) {
            Write-Ok "$($step.Key) — upstream reachable"
        } else {
            Write-Fail "$($step.Key) — NOT reachable: $($step.Url)"
            $dead += $step.Key
        }
    }
    if ($dead) {
        Write-Host ''
        Write-Fail "Unreachable upstream for: $($dead -join ', ')"
        Write-Info 'Those steps would fail mid-install. Check your network or proxy.'
        if ((Read-Host '  Continue anyway? (y/N)') -notin 'y', 'Y') { return }
    }
}

$results = [ordered]@{}
$index = 0

foreach ($step in $steps_to_run) {
    $index++
    $tag = if ($step.Required) { 'required' } else { 'optional' }
    Write-Title "[$index/$($steps_to_run.Count)] $($step.Title)  ($tag)"

    $choice = Confirm-Step
    if ($choice -eq 'quit') {
        Write-Info 'Stopping at your request.'
        break
    }
    if ($choice -eq 'skip') {
        Write-Skip 'skipped by user'
        $results[$step.Key] = 'Skipped (user)'
        continue
    }

    try {
        $outcome = & $step.Install
        $results[$step.Key] = if ($outcome) { $outcome } else { 'Done' }
    } catch {
        Write-Fail $_.Exception.Message
        $results[$step.Key] = 'Failed'
    }
}

Write-Title 'What the run did'
foreach ($key in $results.Keys) {
    $value = $results[$key]
    $color = switch -Wildcard ($value) {
        'Installed' { 'Green' }
        'Skipped*'  { 'DarkGray' }
        'Manual'    { 'Yellow' }
        'Failed'    { 'Red' }
        default     { 'Gray' }
    }
    Write-Host ('  {0,-14} {1}' -f $key, $value) -ForegroundColor $color
}

# Verify everything in one pass, rather than trusting each step's own reporting.
if (-not $DryRun) {
    Test-WorkEnvironment | Out-Null
}

Write-Host ''
Write-Info "Pinned apps are held. Release one with:  scoop unhold cmake"
Write-Info 'Open a new shell so PATH changes apply, then re-check with -CheckOnly.'
Write-Host ''
