$global:CURRENT_SCRIPT_DIRECTORY = Split-Path (Split-Path $MyInvocation.MyCommand.Definition)

# ─── Startup timing harness ─────────────────────────────────────────────────
# Timings are always recorded (Stopwatch overhead is negligible); the summary is
# only printed when $global:PROFILE_STARTUP is $true (set in start/variables.ps1,
# or pre-set before dot-sourcing this file). Stopwatch bracketing is used instead
# of Measure-Command so that dot-sourced files keep loading into this scope.
$global:__INIT_TIMINGS = [ordered]@{}
$__initName = $MyInvocation.MyCommand.Name

$__sw = [System.Diagnostics.Stopwatch]::StartNew()
Get-ChildItem (Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "core\*ps1"   ) | ForEach-Object { if ($_.Name -ne $__initName) { & $_.FullName } }
$global:__INIT_TIMINGS['core\*']  = $__sw.Elapsed.TotalMilliseconds

$__sw = [System.Diagnostics.Stopwatch]::StartNew()
Get-ChildItem (Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "start\*ps1"  ) | ForEach-Object {
    $__fsw = [System.Diagnostics.Stopwatch]::StartNew()
    & $_.FullName
    $global:__INIT_TIMINGS["start\$($_.Name)"] = $__fsw.Elapsed.TotalMilliseconds
}
$global:__INIT_TIMINGS['start\* (total)'] = $__sw.Elapsed.TotalMilliseconds

$__sw = [System.Diagnostics.Stopwatch]::StartNew()
& (Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "apps\init-apps.ps1")
$global:__INIT_TIMINGS['apps\init-apps.ps1 (total)'] = $__sw.Elapsed.TotalMilliseconds

$__sw = [System.Diagnostics.Stopwatch]::StartNew()
& (Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "modules\init-modules.ps1")
$global:__INIT_TIMINGS['modules\init-modules.ps1 (total)'] = $__sw.Elapsed.TotalMilliseconds

$__sw = [System.Diagnostics.Stopwatch]::StartNew()
. (Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "functions\init-functions.ps1")
$global:__INIT_TIMINGS['functions\init-functions.ps1 (total)'] = $__sw.Elapsed.TotalMilliseconds

$__sw = [System.Diagnostics.Stopwatch]::StartNew()
$utilsDir = Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "utils"
$utilsPaths = @($utilsDir) + @(Get-ChildItem -Path $utilsDir -Directory | ForEach-Object { $_.FullName })
$env:PATH = ($utilsPaths -join [IO.Path]::PathSeparator) + [IO.Path]::PathSeparator + $env:PATH
$env:PATH = (Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "test") + [IO.Path]::PathSeparator + $env:PATH
$global:__INIT_TIMINGS['PATH setup'] = $__sw.Elapsed.TotalMilliseconds

if ($global:PROFILE_STARTUP) {
    Write-Host "`n─── EasyPwsh startup timings (ms, desc) ───" -ForegroundColor Cyan
    $global:__INIT_TIMINGS.GetEnumerator() |
        Sort-Object -Property Value -Descending |
        ForEach-Object { '{0,10:N1}  {1}' -f $_.Value, $_.Key } |
        Write-Host
    $__grand = ($global:__INIT_TIMINGS.GetEnumerator() |
        Where-Object { $_.Key -match '\(total\)$|^core\\|^PATH|^start\\\* \(total\)' } |
        Measure-Object -Property Value -Sum).Sum
    Write-Host ('{0,10:N1}  {1}' -f $__grand, 'GRAND TOTAL (top-level)') -ForegroundColor Yellow
}
