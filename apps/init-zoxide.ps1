<#
.SYNOPSIS
    Initialize zoxide
.NOTES
    https://github.com/ajeetdsouza/zoxide
#>

#region zoxide initialize
if (-not (Get-Command 'zoxide' -ErrorAction SilentlyContinue)) {
    return
}

# zoxide's hook must load eagerly (it tracks every `cd`), but its init output is
# deterministic — cache it and regenerate only when zoxide.exe changes, so we
# don't spawn zoxide on every shell start.
$__zoxideDir   = Join-Path $global:CURRENT_SCRIPT_DIRECTORY 'downloads\cache'
$__zoxideCache = Join-Path $__zoxideDir 'zoxide-init.ps1'
$__zoxideExe   = (Get-Command zoxide -CommandType Application | Select-Object -First 1).Source
if (-not (Test-Path $__zoxideCache) -or
    ((Get-Item $__zoxideExe).LastWriteTimeUtc -gt (Get-Item $__zoxideCache).LastWriteTimeUtc)) {
    if (-not (Test-Path $__zoxideDir)) { New-Item -ItemType Directory -Force -Path $__zoxideDir | Out-Null }
    (zoxide init powershell | Out-String) | Set-Content -LiteralPath $__zoxideCache -Encoding UTF8
}
. $__zoxideCache
Set-Alias -Name cd -Value z -Option AllScope -Scope Global -Force
#endregion