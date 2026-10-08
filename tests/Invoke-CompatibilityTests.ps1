[CmdletBinding()]
param([string]$PowerShell7Path,
      [string]$WindowsPowerShellPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe",
      [switch]$AllowMissingEngine)
$ErrorActionPreference = 'Stop'
$testScript = Join-Path $PSScriptRoot 'Test-Compatibility.ps1'
$engines = [ordered]@{ 'Windows PowerShell 5.1' = $WindowsPowerShellPath }
if (-not $PSBoundParameters.ContainsKey('PowerShell7Path')) {
    $command = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { $PowerShell7Path = $command.Source }
}
$engines['PowerShell 7.x'] = $PowerShell7Path
# Fail before running either suite when complete validation is impossible.
$unavailable = @($engines.GetEnumerator() | Where-Object { -not $_.Value -or -not (Test-Path -LiteralPath $_.Value) })
if ($unavailable.Count -and -not $AllowMissingEngine) {
    throw "UNVERIFIED: missing $($unavailable.Key -join ', '). Use -AllowMissingEngine to explicitly allow partial validation."
}
$missing = @()
foreach ($entry in $engines.GetEnumerator()) {
    if (-not $entry.Value -or -not (Test-Path -LiteralPath $entry.Value)) {
        Write-Warning "UNVERIFIED: $($entry.Key) executable unavailable."
        $missing += $entry.Key
        continue
    }
    $expectedMajor = if ($entry.Key -eq 'Windows PowerShell 5.1') { 5 } else { 7 }
    & $entry.Value -NoLogo -NoProfile -ExecutionPolicy Bypass -File $testScript -ExpectedMajor $expectedMajor
    if ($LASTEXITCODE -ne 0) { throw "$($entry.Key) compatibility suite failed ($LASTEXITCODE)" }
    # Every installed compatible PSReadLine is tested in a separate process;
    # loaded .NET assemblies cannot reliably switch versions inside a session.
    $versions = & $entry.Value -NoProfile -Command 'Get-Module -ListAvailable PSReadLine | Select-Object -ExpandProperty Version -Unique | ForEach-Object { $_.ToString() }'
    if ($LASTEXITCODE -ne 0) { throw "$($entry.Key) module discovery failed" }
    foreach ($version in $versions) {
        & $entry.Value -NoLogo -NoProfile -ExecutionPolicy Bypass -File $testScript -ModuleOnly -PSReadLineVersion $version -ExpectedMajor $expectedMajor
        if ($LASTEXITCODE -ne 0) { throw "$($entry.Key) PSReadLine $version configuration failed" }
    }
}
if ($missing.Count) { Write-Warning "Incomplete validation: $($missing -join ', ')." }
else { Write-Host 'PASS: both engine suites completed.' }
