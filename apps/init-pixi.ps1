<#
.SYNOPSIS
    Initialize pixi
.NOTES
    https://github.com/prefix-dev/pixi
#>

#region pixi initialize
if (-not (Get-Command "pixi" -ErrorAction SilentlyContinue)) {
    # Opt-in (start\variables.ps1): a shell start should not download and execute
    # a remote script on its own.
    if (-not $global:PIXI_AUTO_INSTALL) { return }

    Write-Host "pixi is not installed. The official installer will be downloaded from https://pixi.sh/install.ps1" -ForegroundColor Yellow
    $confirm = Read-Host -Prompt "Do you want to install pixi? (y/N)"
    if ($confirm -ne "y" -and $confirm -ne "Y") { return }

    try {
        Invoke-RestMethod -Uri 'https://pixi.sh/install.ps1' | Invoke-Expression
        Write-Host "pixi installed." -ForegroundColor Green
    } catch {
        Write-Host "Failed to install pixi: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    if (-not (Get-Command "pixi" -ErrorAction SilentlyContinue)) { return }
}

# Cache the generated completion script; regenerate only when pixi.exe changes.
# Avoids spawning pixi (~160ms) on every shell start.
$__pixiDir   = Join-Path $global:CURRENT_SCRIPT_DIRECTORY 'downloads\cache'
$__pixiCache = Join-Path $__pixiDir 'pixi-completion.ps1'
$__pixiExe   = (Get-Command pixi -CommandType Application | Select-Object -First 1).Source
if (-not (Test-Path $__pixiCache) -or
    ((Get-Item $__pixiExe).LastWriteTimeUtc -gt (Get-Item $__pixiCache).LastWriteTimeUtc)) {
    if (-not (Test-Path $__pixiDir)) { New-Item -ItemType Directory -Force -Path $__pixiDir | Out-Null }
    (& $__pixiExe completion --shell powershell) | Out-String |
        Set-Content -LiteralPath $__pixiCache -Encoding UTF8
}
. $__pixiCache
#endregion
