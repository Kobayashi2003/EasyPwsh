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
$__zoxideCache = Join-Path $__zoxideDir ('zoxide-init-utf8-ps{0}.ps1' -f $PSVersionTable.PSVersion.Major)
$__zoxideExe   = (Get-Command zoxide -CommandType Application | Select-Object -First 1).Source
if (-not (Test-Path $__zoxideCache) -or
    ((Get-Item $__zoxideExe).LastWriteTimeUtc -gt (Get-Item $__zoxideCache).LastWriteTimeUtc)) {
    if (-not (Test-Path $__zoxideDir)) { New-Item -ItemType Directory -Force -Path $__zoxideDir | Out-Null }
    $hook = Invoke-EasyPwshUtf8Command -FilePath $__zoxideExe -ArgumentList @('init', 'powershell')
    [IO.File]::WriteAllText($__zoxideCache, $hook, [Text.UTF8Encoding]::new($true))
}
. $__zoxideCache
if (Get-Command Set-FnmOnLoad -CommandType Function -ErrorAction SilentlyContinue) {
    # fnm initializes before zoxide; keep both directory hooks active.
    function global:__zoxide_cd_with_fnm {
        z @args
        if ($?) { Set-FnmOnLoad }
    }
    Set-Alias -Name cd -Value __zoxide_cd_with_fnm -Option AllScope -Scope Global -Force
} else {
    Set-Alias -Name cd -Value z -Option AllScope -Scope Global -Force
}
#endregion
