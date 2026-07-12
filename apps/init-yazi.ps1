<#
.SYNOPSIS
    Initialize yazi
.NOTES
    https://yazi-rs.github.io/docs/installation/
#>

#region yazi initialize
if (-not (Get-Command 'yazi' -ErrorAction SilentlyContinue)) {
    return
}

if ($IsLinux) {
    $yazi_config_dir = Join-Path $HOME -ChildPath ".config/yazi"
    $yazi_config_src = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "config/yazi"
} else {
    $yazi_config_dir = Join-Path $env:APPDATA -ChildPath "yazi\config"
    $yazi_config_src = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "config\yazi"
}

# Create symbolic links for configuration files
foreach ($file in @("yazi.toml", "keymap.toml", "theme.toml")) {
    New-ManagedSymlink -Path (Join-Path $yazi_config_dir -ChildPath $file) `
                       -Target (Join-Path $yazi_config_src -ChildPath $file)
}

# yazi uses Git's bundled file.exe for MIME detection. $env:GIT_INSTALL_ROOT is
# not set by every Git install (and never by Scoop), so probe for the real path.
if (-not $IsLinux -and (Get-Command 'git' -ErrorAction SilentlyContinue)) {
    $git_source = (Get-Command 'git' -CommandType Application | Select-Object -First 1).Source
    $git_roots = @(
        $env:GIT_INSTALL_ROOT
        # <root>\cmd\git.exe or <root>\bin\git.exe
        (Split-Path -Parent (Split-Path -Parent $git_source))
        # Scoop puts a shim on PATH, so resolve the app directory instead.
        $(if ($env:SCOOP) { Join-Path $env:SCOOP -ChildPath "apps\git\current" })
    ) | Where-Object { $_ }

    foreach ($root in $git_roots) {
        $file_exe = Join-Path $root -ChildPath "usr\bin\file.exe"
        if (Test-Path -LiteralPath $file_exe) {
            $env:YAZI_FILE_ONE = $file_exe
            break
        }
    }
}
#endregion