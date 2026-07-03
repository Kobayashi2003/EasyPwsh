<#
.SYNOPSIS
    Initialize pixi
.NOTES
    https://github.com/prefix-dev/pixi
#>

#region pixi initialize
if (-not (Get-Command "pixi" -ErrorAction SilentlyContinue)) {
    Write-Host "pixi not installed. Installing..." -ForegroundColor Yellow
    try {
        iwr -useb https://pixi.sh/install.ps1 | iex
        Write-Host "pixi installed." -ForegroundColor Green
    } catch {
        Write-Host "Failed to install pixi." -ForegroundColor Red
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
