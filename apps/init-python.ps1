<#!
.SYNOPSIS
    Initialize python helper functions
#>

if (-not (Get-Command "python" -ErrorAction SilentlyContinue)) {
    return
}

Set-Alias -Name py -Value python -Scope Global