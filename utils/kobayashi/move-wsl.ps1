<#
.SYNOPSIS
    Relocates installed WSL distribution(s) to a new root directory
.DESCRIPTION
    This PowerShell script moves one or more WSL distributions to a new root
    directory using the officially supported export -> unregister -> import
    cycle. It never touches distributions outside the ones selected.

    For every distribution it:
      1. resolves its current install location, WSL version, default user id
         and default-distro flag straight from the registry
         (HKCU:\...\Lxss), never a hard-coded path,
      2. terminates just that distribution (wsl --terminate) so no file is
         locked by a running instance,
      3. exports it to a temporary .tar file under the destination root,
      4. unregisters the old registration only after the export is verified
         to be non-empty,
      5. imports the tar into the new root, then restores the original
         default user id and default-distro flag (import always resets the
         former to root/uid 0 and clears the latter).

    Before anything is touched a change map is printed: distributions that
    will move are highlighted, distributions that stay where they are
    (already at the destination, excluded, not selected, or Store-managed)
    are dimmed.

    Distributions installed from the Microsoft Store (identified by a
    PackageFamilyName registration) are skipped by default, since importing
    them detaches them from the Store (loses auto-update and the Store
    uninstall entry) - use -IncludeStoreManaged to move them anyway.
.PARAMETER Destination
    The new root directory that will hold the relocated distributions, e.g.
    D:\Temp\WSL. Each distribution keeps its own name as a subfolder below
    that root.
.PARAMETER DistroName
    One or more distribution names to move, e.g. Ubuntu. By default *all*
    registered distributions are considered.
.PARAMETER Exclude
    One or more distribution names to leave untouched.
.PARAMETER IncludeStoreManaged
    Also move distributions installed from the Microsoft Store. They lose
    their Store association after being imported back.
.PARAMETER KeepExport
    Keep the intermediate .tar export under the destination instead of
    deleting it after a successful import.
.PARAMETER DryRun
    Only print the change map, then exit without moving anything.
.PARAMETER Force
    Skip the interactive confirmation prompt.
.EXAMPLE
    PS> ./move-wsl.ps1 D:\Temp\WSL
.EXAMPLE
    PS> ./move-wsl.ps1 D:\Temp\WSL Ubuntu
.EXAMPLE
    PS> ./move-wsl.ps1 -Destination D:\Temp\WSL -Exclude Debian -DryRun
.NOTES
    Author: KOBAYASHI
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Destination,

    [Parameter(Mandatory = $false, Position = 1)]
    [string[]]$DistroName = @(),

    [Parameter(Mandatory = $false)]
    [string[]]$Exclude = @(),

    [switch]$IncludeStoreManaged,

    [switch]$KeepExport,

    [switch]$DryRun,

    [switch]$Force
)

function Get-WslRegistrations {
    $lxssRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxssRoot)) { return @() }

    $rootProps = Get-ItemProperty $lxssRoot -ErrorAction SilentlyContinue
    $defaultKeyName = $rootProps.DefaultDistribution

    Get-ChildItem $lxssRoot | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath
        if (-not $p.DistributionName) { return }
        [PSCustomObject]@{
            KeyName           = $_.PSChildName
            Name              = $p.DistributionName
            BasePath          = [IO.Path]::GetFullPath($p.BasePath).TrimEnd('\')
            Version           = if ($p.Version) { $p.Version } else { 1 }
            DefaultUid        = $p.DefaultUid
            PackageFamilyName = $p.PackageFamilyName
            IsDefault         = ($_.PSChildName -eq $defaultKeyName)
        }
    }
}

try {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw "wsl.exe not found on this machine" }

    $destinationRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Destination))

    $distros = @(Get-WslRegistrations)
    if ($distros.Count -eq 0) { throw "No registered WSL distributions found." }

    # --- build the plan ----------------------------------------------------
    $plan = foreach ($d in $distros) {
        $target = Join-Path $destinationRoot $d.Name
        $reason = $null

        if ($DistroName.Count -gt 0 -and $d.Name -notin $DistroName) {
            $reason = 'not selected'
        } elseif ($d.Name -in $Exclude) {
            $reason = 'excluded'
        } elseif ($d.BasePath -ieq $target.TrimEnd('\')) {
            $reason = 'already there'
        } elseif ($d.PackageFamilyName -and -not $IncludeStoreManaged) {
            $reason = 'Store-managed (use -IncludeStoreManaged)'
        }

        [PSCustomObject]@{
            Name       = $d.Name
            Current    = $d.BasePath
            Target     = $target
            Version    = $d.Version
            DefaultUid = $d.DefaultUid
            IsDefault  = $d.IsDefault
            Skip       = [bool]$reason
            Reason     = $reason
        }
    }

    # --- print the change map ----------------------------------------------
    $nameWidth = ($plan.Name | Measure-Object -Maximum -Property Length).Maximum
    $fromWidth = ($plan.Current | Measure-Object -Maximum -Property Length).Maximum

    Write-Host ""
    Write-Host "Destination root: $destinationRoot"
    Write-Host ""

    foreach ($item in $plan) {
        $line = "  {0} {1} -> " -f $item.Name.PadRight($nameWidth), $item.Current.PadRight($fromWidth)
        if ($item.Skip) {
            Write-Host ($line + "(unchanged: $($item.Reason))") -ForegroundColor DarkGray
        } else {
            Write-Host $line -NoNewline
            Write-Host $item.Target -ForegroundColor Green
        }
    }

    $moves = @($plan | Where-Object { -not $_.Skip })
    Write-Host ""
    Write-Host "$($moves.Count) of $($plan.Count) distribution(s) will be moved."

    if ($DryRun) {
        Write-Host "Dry run - nothing was changed." -ForegroundColor Yellow
        exit 0
    }
    if ($moves.Count -eq 0) {
        Write-Host "Nothing to do." -ForegroundColor Yellow
        exit 0
    }

    # --- confirm -------------------------------------------------------------
    if (-not $Force) {
        $answer = Read-Host "Proceed? [y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host "Aborted." -ForegroundColor Yellow
            exit 0
        }
    }

    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null

    # --- move ------------------------------------------------------------------------
    $failed = 0
    foreach ($item in $moves) {
        Write-Host ""
        Write-Host "-> $($item.Name): $($item.Current) -> $($item.Target)" -ForegroundColor Cyan

        $tarPath = Join-Path $destinationRoot "$($item.Name).$([guid]::NewGuid().ToString('N')).tar"
        try {
            Write-Host "  terminating..."
            & wsl.exe --terminate $item.Name 2>$null | Out-Null

            Write-Host "  exporting..."
            & wsl.exe --export $item.Name $tarPath
            if ($LASTEXITCODE -ne 0) { throw "wsl --export failed (exit $LASTEXITCODE)" }
            $tarInfo = Get-Item -LiteralPath $tarPath -ErrorAction Stop
            if ($tarInfo.Length -eq 0) { throw "exported archive is empty, aborting before touching the original" }

            Write-Host "  unregistering old location..."
            & wsl.exe --unregister $item.Name
            if ($LASTEXITCODE -ne 0) { throw "wsl --unregister failed (exit $LASTEXITCODE) - export kept at $tarPath" }

            Write-Host "  importing to new location..."
            if (-not (Test-Path -LiteralPath $item.Target)) {
                New-Item -ItemType Directory -Path $item.Target -Force | Out-Null
            }
            & wsl.exe --import $item.Name $item.Target $tarPath --version $item.Version
            if ($LASTEXITCODE -ne 0) { throw "wsl --import failed (exit $LASTEXITCODE) - the distro is unregistered; re-import manually from $tarPath" }

            $newKey = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' |
                Where-Object { (Get-ItemProperty $_.PSPath).DistributionName -eq $item.Name } |
                Select-Object -First 1
            if ($newKey -and $item.DefaultUid) {
                Set-ItemProperty -Path $newKey.PSPath -Name DefaultUid -Value $item.DefaultUid
            }
            if ($item.IsDefault) {
                & wsl.exe --set-default $item.Name | Out-Null
            }

            if (-not $KeepExport) {
                Remove-Item -LiteralPath $tarPath -Force
            }

            Write-Host "  done" -ForegroundColor Green
        } catch {
            $failed++
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    Write-Host ""
    if ($failed -gt 0) {
        Write-Host "Finished with $failed failure(s)." -ForegroundColor Red
    } else {
        Write-Host "Finished. All $($moves.Count) distribution(s) moved." -ForegroundColor Green
        Write-Host "Run 'wsl --shutdown' once if a distro still shows the old state." -ForegroundColor Yellow
    }

    exit $(if ($failed -gt 0) { 1 } else { 0 })
} catch {
    Write-Host "Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])" -ForegroundColor Red
    exit 1
}
