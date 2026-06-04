# Static lookup tables — built once at load time instead of on every prompt render.
# All icons are single UTF-16 code-unit (BMP) glyphs on purpose: characters above
# U+FFFF (most emoji) are surrogate pairs and get mangled into "??" when PSReadLine
# re-renders the prompt via InvokePrompt() (e.g. after alt+r). Keep these < U+FFFF.
$global:__PromptSpecialIcons = @{
    $env:USERPROFILE                = '⌂'   # home
    "$env:USERPROFILE\Documents"    = '▤'   # documents
    "$env:USERPROFILE\Downloads"    = '↓'   # downloads
    "$env:USERPROFILE\Pictures"     = '▦'   # pictures
    "$env:USERPROFILE\Videos"       = '▶'   # videos
    "$env:USERPROFILE\Music"        = '♪'   # music
    "$env:USERPROFILE\Desktop"      = '▭'   # desktop
    "$env:USERPROFILE\OneDrive"     = '☁'   # onedrive
    "$env:USERPROFILE\.ssh"         = '⚷'   # ssh / keys
    "$env:USERPROFILE\.config"      = '⚙'   # config
    'C:\Program Files'              = '◰'   # packages
    'C:\Program Files (x86)'        = '◰'
    'C:\Windows'                    = '▦'   # windows
    'C:\Users'                      = '☰'   # users
    'C:\Temp'                       = '⌫'   # temp
    'C:\ProgramData'                = '▣'   # program data
}

# Folder names (matched against the last path segment) -> icon.
$global:__PromptNamedIcons = @{
    src          = '§';  source       = '§'
    lib          = '≣';  include      = '‡'
    docs         = '▤';  scripts      = '»'
    test         = '✓';  tests        = '✓'
    node_modules = '◰';  packages     = '◰';  vendor   = '◰';  resources = '◰'
    venv         = 'λ';  '.venv'      = 'λ'
    build        = '◆';  dist         = '◆';  target   = '◆'
    '.git'       = '⎇';  config       = '⚙';  tools    = '⚙';  utils     = '⚙'
    bin          = '▦';  data         = '▣';  assets   = '▨'
    public       = '☼';  private      = '⚷'
}

function global:prompt {
    $lst_cmd_state = $?
    $esc = $([char]27)

    # Cache the history lookup — Get-History was previously called up to 3x per prompt.
    $history = Get-History
    if ($history.Count -ge 1) {
        $last = $history[-1]
        $executionTime = ($last.EndExecutionTime - $last.StartExecutionTime).TotalMilliseconds
    } else {
        $executionTime = 0
    }
    $executionTime = [math]::Round($executionTime, 2)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal] $identity
    $adminRole = [Security.Principal.WindowsBuiltInRole]::Administrator
    $isAdmin = $principal.IsInRole($adminRole)
    $curUser = $env:USERNAME

    $promptChar = if ($isAdmin) { "#" } else { "$" }

    $promptString = ""

    if ($env:CONDA_DEFAULT_ENV) {
        $promptString += "$esc[1;33m($env:CONDA_DEFAULT_ENV)$esc[0m "
    }

    if (Test-Path variable:/PSDebugContext) {
        $promptString += "$esc[1;32m[D]$esc[0m "
    } elseif ($isAdmin) {
        $promptString += "$esc[1;31m[A]$esc[0m "
    } else {
        $promptString += "$esc[1;30m[$($curUser[0])]$esc[0m "
    }

    if ($lst_cmd_state) {
        $promptString += "$esc[1;32m$esc[1;4m$($executionTime)ms$esc[0m "
    } else {
        $promptString += "$esc[1;31m$esc[1;4m$($executionTime)ms$esc[0m "
    }

    # Resolve the path display + icon.
    $path = $PWD.Path
    if ($global:__PromptSpecialIcons.ContainsKey($path)) {
        # Well-known root: show just its landmark icon.
        $path = $global:__PromptSpecialIcons[$path]
    } else {
        $leaf = Split-Path $path -Leaf
        if ($global:__PromptNamedIcons.ContainsKey($leaf)) {
            $path = $global:__PromptNamedIcons[$leaf]
        } else {
            # git rev-parse returns a forward-slash path; normalize before comparing.
            $gitRoot = git rev-parse --show-toplevel 2>$null
            if ($LASTEXITCODE -eq 0 -and $gitRoot) { $gitRoot = $gitRoot -replace '/', '\' }
            if ($gitRoot -and $path.StartsWith($gitRoot)) {
                $repoName = Split-Path $gitRoot -Leaf
                $path = "⎇ $repoName" + $path.Substring($gitRoot.Length)
            } else {
                $path += " ▸"
            }
        }
    }

    while ($path.Length -gt 30 -and $path.replace("..\", "").IndexOf("\") -ne -1) {
        $path = "..\" + $path.Substring($path.IndexOf("\", $path.IndexOf("\") + 1) + 1)
    }
    $promptString += "$esc[1;33m$path$esc[0m "

    if ($NestedPromptLevel -ge 1) {
        $colors_code = @{
            0 = "$esc[1;31m"; 1 = "$esc[1;32m"
            2 = "$esc[1;33m"; 3 = "$esc[1;34m"
            4 = "$esc[1;35m"; 5 = "$esc[1;36m"
        }
        for ($i = 0; $i -lt $NestedPromptLevel; $i++) {
            $promptString += "$($colors_code[$i % 6])$promptChar$esc[0m"
        }
    }
    $promptString += if ($isAdmin) { "$esc[1;31m$promptChar$esc[0m " } else { "$esc[1;34m$promptChar$esc[0m " }

    return $promptString
}
