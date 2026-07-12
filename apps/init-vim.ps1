<#
.SYNOPSIS
    Initialize Vim
.NOTES
    https://github.com/vim/vim
#>

if (-not (Get-Command "vim" -ErrorAction SilentlyContinue)) {
    return
}

if ($IsLinux) {
    $vim_conf = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "config/vim/.vimrc"
    $vim_conf_current_user = Join-Path $HOME -ChildPath ".vimrc"
} else {
    $vim_conf = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "config\vim\_vimrc"
    $vim_conf_current_user = Join-Path $env:USERPROFILE -ChildPath "_vimrc"
}

New-ManagedSymlink -Path $vim_conf_current_user -Target $vim_conf