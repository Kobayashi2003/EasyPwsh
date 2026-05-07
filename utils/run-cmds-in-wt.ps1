<#
.SYNOPSIS
    Open Windows Terminal with split panes, each running one command.
.DESCRIPTION
    Accepts multiple commands and launches a new Windows Terminal window
    with split panes, where each pane executes one command.
.PARAMETER Commands
    One or more commands to run in each split pane.
.PARAMETER NoProfile
    When specified, PowerShell is launched with -NoProfile (skips loading the profile).
.EXAMPLE
    .\run-cmds-in-wt.ps1 "ping google.com" "Get-Process" "Get-Service"
.EXAMPLE
    .\run-cmds-in-wt.ps1 -Commands "npm run dev", "npm run test" -NoProfile
#>
param(
    [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)]
    [string[]]$Commands,

    [switch]$NoProfile
)

if (-not (Get-Command wt -ErrorAction SilentlyContinue)) {
    Write-Error "Windows Terminal (wt) not found. Please install it from the Microsoft Store."
    exit 1
}

$shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
$profileFlag = if ($NoProfile) { "-NoProfile" } else { "" }
$shellFlags  = (@($profileFlag, "-NoExit") | Where-Object { $_ -ne "" }) -join " "

# Use -EncodedCommand (Base64) to avoid all quoting issues through Start-Process.
function New-PaneInvoke([string]$Cmd) {
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Cmd))
    return "-- $shell $shellFlags -EncodedCommand $encoded"
}

# Grid: cols = ceil(sqrt(N)), rows = ceil(N / cols), filled row-first.
$n    = $Commands.Count
$cols = [Math]::Ceiling([Math]::Sqrt($n))
$rows = [Math]::Ceiling($n / $cols)

$parts = @("new-tab $(New-PaneInvoke $Commands[0])")
$idx   = 1

# Phase 1: vertical splits to create $cols equal-width columns.
# Each split carves the right portion from the previous rightmost pane.
for ($c = 1; $c -lt $cols -and $idx -lt $n; $c++) {
    $s = [Math]::Round(($cols - $c) / ($cols - $c + 1.0), 4)
    $parts += "focus-pane -t $($c - 1)"
    $parts += "split-pane -V -s $s $(New-PaneInvoke $Commands[$idx++])"
}

# Phase 2: horizontal splits to fill rows within each column.
# Column $c's top pane index is always $c (creation order from Phase 1).
$bottomPane = [int[]](0..($cols - 1))
$nextId     = $cols
for ($r = 1; $r -lt $rows; $r++) {
    $s = [Math]::Round(($rows - $r) / ($rows - $r + 1.0), 4)
    for ($c = 0; $c -lt $cols -and $idx -lt $n; $c++) {
        $parts += "focus-pane -t $($bottomPane[$c])"
        $parts += "split-pane -H -s $s $(New-PaneInvoke $Commands[$idx++])"
        $bottomPane[$c] = $nextId++
    }
}

$argArray = @()
for ($i = 0; $i -lt $parts.Count; $i++) {
    if ($i -gt 0) { $argArray += ";" }
    $argArray += $parts[$i] -split '\s+'
}
& wt $argArray
