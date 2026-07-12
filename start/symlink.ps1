<#
.SYNOPSIS
    Shared helper for linking a repo-managed config file into its expected
    location in the user's home directory.
#>

function global:New-ManagedSymlink {
<#
.SYNOPSIS
    Link $Path to $Target, creating any missing parent directories.
.DESCRIPTION
    Creating a symlink only needs elevation when Windows Developer Mode is off,
    so try unelevated first and fall back to `sudo` (start/sudo.ps1, which
    prompts for UAC).

    A no-op when $Path already resolves to $Target, so init-*.ps1 scripts can
    call this on every shell start.
.PARAMETER Path
    The link to create (e.g. ~/.condarc).
.PARAMETER Target
    The file the link points at (e.g. <repo>/config/conda/.condarc).
#>
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,
        [Parameter(Mandatory, Position = 1)]
        [string] $Target
    )

    if (-not (Test-Path -LiteralPath $Target)) {
        Write-Warning "Link target does not exist, skipping: $Target"
        return
    }

    $existing = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($existing) {
        # A real file the user put there themselves is left alone, not replaced.
        if ($existing.LinkTarget -eq (Resolve-Path -LiteralPath $Target).Path) { return }
        Write-Warning "Not linking $Path -> $Target (path already exists)."
        return
    }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }

    try {
        New-Item -Path $Path -ItemType SymbolicLink -Value $Target -ErrorAction Stop | Out-Null
        return
    } catch {
        Write-Verbose "Unelevated symlink failed, retrying with sudo: $($_.Exception.Message)"
    }

    try {
        if ($IsLinux -or $IsMacOS) {
            & sudo ln -s $Target $Path
        } else {
            & sudo New-Item -Path $Path -ItemType SymbolicLink -Value $Target
        }
    } catch {
        Write-Warning "Failed to link $Path -> $Target`: $($_.Exception.Message)"
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Warning "Failed to link $Path -> $Target."
    }
}
