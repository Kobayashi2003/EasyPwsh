<#
.SYNOPSIS
    Initialize ripgrep
.NOTES
    https://github.com/BurntSushi/ripgrep
#>

if (-not (Get-Command 'rg' -ErrorAction SilentlyContinue)) {
    return
}

Set-Alias -Name grep -Value rg -Option AllScope -Scope Global -Force