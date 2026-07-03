<#
.SYNOPSIS
    Initialize bat
.NOTES
    https://github.com/sharkdp/bat
#>

#region bat initialize
if (-not (Get-Command 'bat' -ErrorAction SilentlyContinue)) {
    return
}

Set-Alias -Name cat -Value bat -Option AllScope -Scope Global -Force
#endregion