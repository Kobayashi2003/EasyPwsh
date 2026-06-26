<#
.SYNOPSIS
    Finds and removes duplicate Windows Firewall rules interactively.
.DESCRIPTION
    Displays a menu to choose scope (Inbound/Outbound/All), lists all duplicate
    rules, backs up current firewall settings, then removes duplicates (keeping
    one rule per group).
.PARAMETER Scope
    Rule scope to inspect: Inbound, Outbound, or All. If omitted, shows a menu.
.EXAMPLE
    PS> ./clean-firewall-rules.ps1
.EXAMPLE
    PS> ./clean-firewall-rules.ps1 -Scope All
.NOTES
    Author: KOBAYASHI
#>

#Requires -RunAsAdministrator

param(
    [ValidateSet('Inbound', 'Outbound', 'All')]
    [string]$Scope = ""
)

$comparisonProperties = @(
    'DisplayName', 'Direction', 'Action', 'Enabled', 'Profile', 'Protocol',
    'LocalPort', 'RemotePort', 'LocalAddress', 'RemoteAddress', 'Program', 'Service'
)

function Get-DuplicateRules([string]$scope) {
    $rules = switch ($scope) {
        'Inbound'  { Get-NetFirewallRule -Direction Inbound  -ErrorAction SilentlyContinue }
        'Outbound' { Get-NetFirewallRule -Direction Outbound -ErrorAction SilentlyContinue }
        'All'      { Get-NetFirewallRule -ErrorAction SilentlyContinue }
    }
    return $rules | Group-Object -Property $comparisonProperties | Where-Object { $_.Count -gt 1 }
}

function Show-DuplicateResults($groups) {
    if ($groups) {
        $redundant = ($groups | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum).Sum
        Write-Host "Found $($groups.Count) duplicate group(s), $redundant redundant rule(s):" -ForegroundColor Yellow
        $groups | ForEach-Object {
            Write-Host "  '$($_.Group[0].DisplayName)' ($($_.Count) rules, $($_.Count - 1) to remove)" -ForegroundColor Green
            $_.Group | Select-Object Name, Description | Format-Table -AutoSize
        }
        return $true
    }
    Write-Host "No duplicate firewall rules found." -ForegroundColor Green
    return $false
}

function Backup-Rules {
    try {
        $backupDir = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "Firewall_Backups"
        if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
        $backupPath = Join-Path $backupDir "firewall_backup_$(Get-Date -Format 'yyyy-MM-dd_HHmmss').wfw"
        netsh advfirewall export $backupPath | Out-Null
        Write-Host "Backup saved: $backupPath" -ForegroundColor Green
        return $true
    } catch {
        Write-Error "Backup failed: $_"
        return $false
    }
}

function Remove-DuplicateRules($groups) {
    $total = ($groups | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum).Sum
    $i = 0
    $groups | ForEach-Object {
        $_.Group | Select-Object -Skip 1 | ForEach-Object {
            $i++
            Write-Progress -Activity "Removing duplicates" `
                -Status "Deleting '$($_.DisplayName)'" `
                -PercentComplete (($i / $total) * 100)
            try { Remove-NetFirewallRule -InputObject $_ -ErrorAction Stop }
            catch { Write-Warning "Failed to remove '$($_.Name)': $_" }
        }
    }
    Write-Progress -Activity "Done" -Completed
    Write-Host "Cleanup complete." -ForegroundColor Green
}

# --- Main ---

if (-not $Scope) {
    $choice = 0
    while ($choice -notin 1..4) {
        Write-Host @"

Windows Firewall Duplicate Rule Cleaner
========================================
  1. Inbound rules only
  2. Outbound rules only
  3. All rules
  4. Exit
========================================
"@
        $raw = Read-Host "Select"
        if ($raw -match '^\d+$') { $choice = [int]$raw }
    }
    if ($choice -eq 4) { exit }
    $Scope = @{ 1 = 'Inbound'; 2 = 'Outbound'; 3 = 'All' }[$choice]
}

Write-Host "Scanning $Scope rules..." -ForegroundColor Cyan
$duplicates = Get-DuplicateRules $Scope
$hasDuplicates = Show-DuplicateResults $duplicates

if ($hasDuplicates) {
    $confirm = Read-Host "Backup and remove duplicates? (Y to confirm)"
    if ($confirm -eq 'Y' -or $confirm -eq 'y') {
        if (Backup-Rules) {
            Remove-DuplicateRules $duplicates
            Write-Host "--- Post-cleanup verification ---" -ForegroundColor Cyan
            Show-DuplicateResults (Get-DuplicateRules $Scope) | Out-Null
        } else {
            Write-Host "Cleanup aborted due to backup failure." -ForegroundColor Red
        }
    } else {
        Write-Host "Cancelled. No changes made." -ForegroundColor Yellow
    }
}

Read-Host "Press Enter to exit"
