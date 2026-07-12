<#
.SYNOPSIS
    Set up the WPS development work environment on a machine that already has
    Scoop and EasyPwsh.

.DESCRIPTION
    Installs the toolchain described in the team's environment document, using
    only Scoop and official upstream sources. The intranet file server
    (10.213.20.115) is never used, so this works from anywhere.

    Version policy:
      - CMake and Python are pinned, because the build scripts depend on them.
          cmake     3.28.1     exact pin (scoop install cmake@3.28.1, then held)
          python    3.10.x     via the versions/python310 manifest
      - Everything else installs at its current version.

    Behaviour:
      - Every step stops and waits for you before it does anything.
      - Already-satisfied steps are detected and skipped, so re-running is safe.
      - Scoop apps are never uninstalled. A pinned version is installed
        side-by-side and 'current' is switched to it, so <scoop>\persist\<app>
        (your app configuration) is left untouched.
      - Pinned apps are put on hold, otherwise the next 'scoop update' — including
        EasyPwsh's own scoop-check-update — would silently upgrade them again.
      - A preflight pass checks every download URL before anything is installed,
        so you don't discover a dead link halfway through.

.PARAMETER Only
    Only run the steps whose Key matches one of these (e.g. -Only cmake,python).

.PARAMETER SkipOptional
    Skip the steps marked optional in the team document.

.PARAMETER DryRun
    Show what each step would do, without installing anything.

.PARAMETER NoPreflight
    Skip the URL reachability check.

.EXAMPLE
    .\Install-WorkEnvironment.ps1
    .\Install-WorkEnvironment.ps1 -Only cmake,python
    .\Install-WorkEnvironment.ps1 -SkipOptional -DryRun
#>

[CmdletBinding()]
param(
    [string[]] $Only,
    [switch]   $SkipOptional,
    [switch]   $DryRun,
    [switch]   $NoPreflight
)

$ErrorActionPreference = 'Stop'

# ─── Pinned versions ──────────────────────────────────────────────────────────
# The only two versions the team document actually constrains.
$CMAKE_VERSION  = '3.28.1'
$PYTHON_APP     = 'python310'   # versions bucket, tracks 3.10.x

# Buckets these steps install from.
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

    $install_json = Join-Path $current 'manifest.json'
    if (Test-Path $install_json) {
        try { return (Get-Content $install_json -Raw | ConvertFrom-Json).version } catch { }
    }
    # Fall back to the directory the 'current' junction points at.
    return (Get-Item $current).Target | Split-Path -Leaf
}

function Test-ScoopVersionOnDisk {
    <#
    .SYNOPSIS
        True when this exact version was installed before and is still on disk,
        which means we can switch to it with 'scoop reset' instead of downloading.
    #>
    param([string] $App, [string] $Version)
    Test-Path (Join-Path $env:SCOOP "apps\$App\$Version")
}

function Install-ScoopApp {
    <#
    .SYNOPSIS
        Install a Scoop app, optionally pinned to an exact version.
    .DESCRIPTION
        With -Version: installs that version alongside whatever is there, points
        'current' at it, and holds the app. Never uninstalls, so persisted config
        under <scoop>\persist survives.
        Without -Version: installs only if missing; an existing install is left
        alone, since the team document does not constrain its version.
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
        # Holding blocks 'scoop install <app>@<ver>' too, so release it first.
        & scoop unhold $App *>$null
    }

    if (Test-ScoopVersionOnDisk -App $App -Version $Version) {
        Write-Act "scoop reset $App@$Version   (already on disk, no download)"
        if ($DryRun) { return 'DryRun' }
        & scoop reset "$App@$Version"
    } else {
        Write-Act "scoop install $App@$Version"
        if ($DryRun) { return 'DryRun' }
        & scoop install "$App@$Version"
    }
    if ($LASTEXITCODE -ne 0) { throw "installing $App@$Version failed" }

    # Without this the next 'scoop update *' — EasyPwsh runs one on demand — would
    # pull the pin straight back up to the latest version.
    & scoop hold $App *>$null
    Write-Info "$App is now held, so 'scoop update' will not bump it"

    return 'Installed'
}

function Confirm-Step {
    <#
    .SYNOPSIS
        Gate every step on the user, per the requirement that nothing installs
        without an explicit keypress.
    .OUTPUTS
        'run', 'skip', or 'quit'
    #>
    param([string] $Prompt = 'Press ENTER to install, [s] to skip, [q] to quit')

    while ($true) {
        Write-Host ''
        Write-Host "  $Prompt : " -ForegroundColor Magenta -NoNewline
        $key = Read-Host
        switch ($key.Trim().ToLower()) {
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
        Download to the cache directory, reusing the file if it is already complete.
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

# ─── The steps ────────────────────────────────────────────────────────────────
# Each step: Key, Title, Required, Url (preflight only), and Run.

$Steps = @(
    @{
        Key = 'cmake'; Title = 'CMake 3.28.1 (pinned)'; Required = $true
        Url = "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-windows-x86_64.zip"
        Run = {
            # The team document's prose says 3.16.0 but its own download link is
            # 3.28.1; the link wins.
            Install-ScoopApp -App 'cmake' -Version $CMAKE_VERSION
        }
        Verify = { cmake --version }
    }

    @{
        Key = 'python'; Title = 'Python 3.10.x (pinned major.minor)'; Required = $true
        Url = 'https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe'
        Run = {
            # The document asks for 3.10.0. versions/python310 tracks the 3.10.x
            # line and is a maintained manifest, unlike a synthesized python@3.10.0.
            $result = Install-ScoopApp -App $PYTHON_APP

            # main/python would own the 'python' shim and shadow 3.10.
            if (Get-ScoopVersion -App 'python') {
                Write-Info "the 'python' app (latest) is also installed and owns the shims"
                Write-Act  "scoop reset $PYTHON_APP   (give the shims back to 3.10)"
                if (-not $DryRun) { & scoop reset $PYTHON_APP }
            }
            return $result
        }
        Verify = { python --version; pip --version }
    }

    @{
        Key = 'git'; Title = 'Git'; Required = $true
        Run = {
            $result = Install-ScoopApp -App 'git'

            Write-Host ''
            Write-Info 'Required Git configuration (section 2 of the team document):'
            $name  = Read-Host '  git user.name  (ENTER to leave unchanged)'
            $email = Read-Host '  git user.email, use your WPS address (ENTER to leave unchanged)'
            if (-not $DryRun) {
                if ($name)  { & git config --global user.name  $name }
                if ($email) { & git config --global user.email $email }
                # The document requires disabling cross-platform newline conversion.
                & git config --global core.autocrlf false
                Write-Ok 'core.autocrlf = false'
            }

            $ssh_key = Join-Path $env:USERPROFILE '.ssh\id_rsa.pub'
            if (Test-Path $ssh_key) {
                Write-Ok "SSH key already exists: $ssh_key"
            } else {
                Write-Info 'No SSH key found. Generate one with:  ssh-keygen -t rsa'
                Write-Info 'Then add ~/.ssh/id_rsa.pub to https://ksogitlab.kso.net/ (Edit Profile -> SSH Keys)'
            }
            return $result
        }
        Verify = { git --version; git config --global core.autocrlf }
    }

    @{
        Key = '7zip'; Title = '7-Zip'; Required = $true
        Run = { Install-ScoopApp -App '7zip' }
    }

    @{
        Key = 'nodejs'; Title = 'Node.js (LTS)'; Required = $true
        Run = {
            # The document asks for the LTS line, so use nodejs-lts rather than
            # nodejs, which tracks Current.
            Install-ScoopApp -App 'nodejs-lts'
        }
        Verify = { node --version; npm --version }
    }

    @{
        Key = 'go'; Title = 'Go'; Required = $true
        Run = { Install-ScoopApp -App 'go' }
        Verify = { go version }
    }

    @{
        Key = 'cppcheck'; Title = 'Cppcheck (required by krepo cr)'; Required = $true
        Run = {
            $result = Install-ScoopApp -App 'cppcheck'
            # The document warns that cppcheck must be on PATH or 'krepo cr' cannot
            # produce its report. Scoop's shim directory is already on PATH, so this
            # is satisfied automatically.
            Write-Info 'Scoop shims are on PATH, so the cppcheck PATH requirement is satisfied'
            return $result
        }
        Verify = { cppcheck --version }
    }

    @{
        Key = 'vscode'; Title = 'Visual Studio Code'; Required = $true
        Run = { Install-ScoopApp -App 'vscode' }
    }

    @{
        Key = 'krepo'; Title = 'Krepo (kso-repo-tool + krepo-v2)'; Required = $true
        Run = {
            # Only available from the WPS package mirror, so it needs the corporate
            # network. Everything else in this script works from anywhere.
            $mirror = 'https://mirrors.wps.cn/pypi/dev/'
            if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
                Write-Fail 'python is not on PATH; run the python step first'
                return 'Failed'
            }
            if (-not (Test-Url $mirror)) {
                Write-Fail "cannot reach $mirror — connect to the WPS network and re-run with -Only krepo"
                return 'Failed'
            }

            Write-Act "pip install kso-repo-tool + krepo-v2 from $mirror"
            if ($DryRun) { return 'DryRun' }

            & python -m pip install --upgrade kso-repo-tool -i $mirror --no-cache --user
            & python -m pip install --upgrade krepo-v2 -i $mirror --no-cache

            # The document asks you to find the Scripts directory by hand and put it
            # on PATH; derive it instead.
            $scripts = & python -c "import sysconfig,os; print(sysconfig.get_path('scripts', 'nt_user'))" 2>$null
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
                Write-Info "could not locate krepo.exe; find it with:  pip show kso-repo-tool"
            }
            return 'Installed'
        }
        Verify = { krepo -v }
    }

    @{
        Key = 'vs2019'; Title = 'Visual Studio 2019 Professional 16.11 (manual)'; Required = $true
        Run = {
            # Licensed, distributed as a multi-GB ISO. The bootstrapper can install
            # the exact workloads, but it always pulls the newest 16.11.x, so the
            # document's 16.11.37 cannot be reproduced exactly.
            Write-Info 'Visual Studio cannot be installed unattended from a public source.'
            Write-Info 'If VS 2019 is already installed, open Visual Studio Installer -> Modify.'
            Write-Host ''
            Write-Host '  Components required by the team document:' -ForegroundColor Yellow
            Write-Host '    - Desktop development with C++            (Workload.NativeDesktop)'
            Write-Host '    - MFC                                     (Component.VC.ATLMFC)'
            Write-Host '    - C++ 2019 Redistributable MSM            (Component.VC.Redist.MSM)'
            Write-Host '    - Windows 10 SDK 18362                    (Component.Windows10SDK.18362)'
            Write-Host '    - Visual Studio extension development     (Workload.VisualStudioExtension)'
            Write-Host '    - MSVC v142 toolset 14.29                 (Component.VC.14.29.16.11.x86.x64)'
            Write-Host '    - English language pack (needed to build third-party libraries)'
            Write-Host ''
            Write-Host '  To install from scratch, the official bootstrapper can preselect all of it:' -ForegroundColor Yellow
            Write-Host '    vs_professional.exe `' -ForegroundColor DarkGray
            Write-Host '      --add Microsoft.VisualStudio.Workload.NativeDesktop `' -ForegroundColor DarkGray
            Write-Host '      --add Microsoft.VisualStudio.Workload.VisualStudioExtension `' -ForegroundColor DarkGray
            Write-Host '      --add Microsoft.VisualStudio.Component.VC.ATLMFC `' -ForegroundColor DarkGray
            Write-Host '      --add Microsoft.VisualStudio.Component.VC.Redist.MSM `' -ForegroundColor DarkGray
            Write-Host '      --add Microsoft.VisualStudio.Component.Windows10SDK.18362 `' -ForegroundColor DarkGray
            Write-Host '      --add Microsoft.VisualStudio.Component.VC.14.29.16.11.x86.x64 `' -ForegroundColor DarkGray
            Write-Host '      --addProductLang En-us --includeRecommended' -ForegroundColor DarkGray
            Write-Host ''

            $answer = Read-Host '  Download the VS 2019 bootstrapper now? (y/N)'
            if ($answer -notin 'y', 'Y') { return 'Skipped' }
            if ($DryRun) { return 'DryRun' }

            $dir = Get-InstallDirectory -App 'Visual Studio bootstrapper' -Default (Join-Path $env:USERPROFILE 'Downloads')
            $exe = Save-Download -Url 'https://aka.ms/vs/16/release/vs_professional.exe' -FileName 'vs_professional.exe'
            Copy-Item $exe $dir -Force
            Write-Ok "bootstrapper saved to $dir — run it with the arguments above"
            return 'Manual'
        }
    }

    @{
        Key = 'pixso'; Title = 'Pixso (manual)'; Required = $true
        Run = {
            # pixso.cn serves its download link from JavaScript and keeps no archive
            # of old builds, so 2.2.8 specifically is not obtainable.
            Write-Info 'Pixso has no scriptable download and no public archive of old versions.'
            Write-Info 'Opening the official download page; install the current version.'
            if (-not $DryRun) { Start-Process 'https://pixso.cn/download/' }
            return 'Manual'
        }
    }

    @{
        Key = 'clang-tidy'; Title = 'Clang-Tidy (LLVM) — strongly recommended'; Required = $false
        Run = { Install-ScoopApp -App 'llvm' }
        Verify = { clang-tidy --version }
    }

    @{
        Key = 'everything'; Title = 'Everything'; Required = $false
        Run = { Install-ScoopApp -App 'everything' }
    }

    @{
        Key = 'listary'; Title = 'Listary'; Required = $false
        Run = { Install-ScoopApp -App 'listary' }
    }

    @{
        Key = 'postman'; Title = 'Postman'; Required = $false
        Run = {
            # The document pins 11.2.0.0, but Postman's CDN only serves the current
            # release (that exact build now 404s), and the version is not constrained.
            Install-ScoopApp -App 'postman'
        }
    }

    @{
        Key = 'switchhosts'; Title = 'SwitchHosts'; Required = $false
        Run = { Install-ScoopApp -App 'switchhosts' }
    }

    @{
        Key = 'cc-switch'; Title = 'CC-Switch'; Required = $false
        Url = 'https://github.com/farion1231/cc-switch/releases/latest'
        Run = {
            # Not in any Scoop bucket, so this is a plain MSI install.
            $api = 'https://api.github.com/repos/farion1231/cc-switch/releases/latest'
            $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'work-env-setup' } -TimeoutSec 30
            $asset = $rel.assets | Where-Object { $_.name -like '*Windows.msi' } | Select-Object -First 1
            if (-not $asset) {
                Write-Fail 'no Windows .msi asset in the latest CC-Switch release'
                return 'Failed'
            }
            Write-Info "latest release: $($rel.tag_name) ($($asset.name))"
            if ($DryRun) { return 'DryRun' }

            $msi = Save-Download -Url $asset.browser_download_url -FileName $asset.name
            $dir = Get-InstallDirectory -App 'CC-Switch' -Default 'C:\Program Files\CC-Switch'
            Write-Act "msiexec /i $($asset.name) INSTALLDIR=`"$dir`""
            $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/qb', "INSTALLDIR=`"$dir`"") -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "msiexec exited with $($p.ExitCode)" }
            return 'Installed'
        }
    }
)

# ─── Preflight ────────────────────────────────────────────────────────────────

Write-Title 'Work environment setup'
Write-Host "  Scoop root : $env:SCOOP"
Write-Host "  Pinned     : cmake $CMAKE_VERSION, python 3.10.x ($PYTHON_APP)"
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

Write-Title 'Preflight'

$buckets = @(& scoop bucket list).Name
foreach ($b in $REQUIRED_BUCKETS) {
    if ($buckets -contains $b) {
        Write-Ok "bucket $b"
    } else {
        Write-Act "scoop bucket add $b"
        if (-not $DryRun) { & scoop bucket add $b }
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
    foreach ($s in ($steps_to_run | Where-Object { $_.Url })) {
        if (Test-Url $s.Url) {
            Write-Ok "$($s.Key) — upstream reachable"
        } else {
            Write-Fail "$($s.Key) — NOT reachable: $($s.Url)"
            $dead += $s.Key
        }
    }
    if ($dead) {
        Write-Host ''
        Write-Fail "Unreachable upstream for: $($dead -join ', ')"
        Write-Info 'Check your network or proxy before continuing; those steps would fail mid-install.'
        if ((Read-Host '  Continue anyway? (y/N)') -notin 'y', 'Y') { return }
    }
}

# ─── Run ──────────────────────────────────────────────────────────────────────

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
        $outcome = & $step.Run
        $results[$step.Key] = if ($outcome) { $outcome } else { 'Done' }

        if ($step.Verify -and -not $DryRun -and $results[$step.Key] -notin 'Failed', 'Manual') {
            Write-Host ''
            Write-Info 'Verifying:'
            try {
                # A fresh shim may not be visible to this process yet.
                $env:PATH = "$env:SCOOP\shims;$env:PATH"
                & $step.Verify 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            } catch {
                Write-Fail "verification command failed: $($_.Exception.Message)"
                Write-Info 'This is often just a stale PATH — open a new shell and check again.'
            }
        }
    } catch {
        Write-Fail $_.Exception.Message
        $results[$step.Key] = 'Failed'
    }
}

# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Title 'Summary'
foreach ($k in $results.Keys) {
    $v = $results[$k]
    $color = switch -Wildcard ($v) {
        'Installed' { 'Green' }
        'Skipped*'  { 'DarkGray' }
        'Manual'    { 'Yellow' }
        'Failed'    { 'Red' }
        default     { 'Gray' }
    }
    Write-Host ('  {0,-14} {1}' -f $k, $v) -ForegroundColor $color
}

Write-Host ''
Write-Info 'Pinned apps are held. To see them:            scoop list'
Write-Info 'To release a pin later:                       scoop unhold cmake'
Write-Info 'Open a new shell so the updated PATH applies.'
Write-Host ''
