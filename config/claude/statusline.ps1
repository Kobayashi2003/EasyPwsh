<#
.SYNOPSIS
    Claude Code statusline renderer.
.DESCRIPTION
    Reads the JSON payload Claude Code writes to stdin and prints a single
    status line: [model] dir (branch) | ctx pct (tokens) | $cost | duration | +/- lines
.NOTES
    Payload schema: https://code.claude.com/docs/en/statusline
#>

$ErrorActionPreference = 'SilentlyContinue'

$payload = [Console]::In.ReadToEnd()
if (-not $payload) { return }
try { $d = $payload | ConvertFrom-Json } catch { return }

# --- ANSI helpers ---
$esc = [char]27
$c = @{
    reset   = "$esc[0m"
    dim     = "$esc[90m"
    cyan    = "$esc[36m"
    yellow  = "$esc[33m"
    magenta = "$esc[35m"
    green   = "$esc[32m"
    red     = "$esc[31m"
    blue    = "$esc[34m"
    bold    = "$esc[1m"
}
function paint($text, $color) { "$color$text$($c.reset)" }

# --- Pieces ---
$parts = New-Object System.Collections.Generic.List[string]

# model
if ($d.model.display_name) {
    $parts.Add((paint "[$($d.model.display_name)]" $c.cyan))
}

# dir
$cwd = if ($d.workspace.current_dir) { $d.workspace.current_dir } else { $d.cwd }
if ($cwd) { $parts.Add((paint (Split-Path -Leaf $cwd) $c.yellow)) }

# git branch (+ dirty marker)
if ($cwd -and (Test-Path $cwd)) {
    Push-Location -Path $cwd
    try {
        $branch = (git symbolic-ref --short HEAD 2>$null)
        if ($branch) {
            $dirty = if ((git status --porcelain 2>$null)) { '*' } else { '' }
            $parts.Add((paint "($($branch.Trim())$dirty)" $c.magenta))
        }
    } finally { Pop-Location }
}

# context usage (color thresholds: <50 green, <80 yellow, else red)
$ctx = $d.context_window
if ($ctx -and $null -ne $ctx.used_percentage) {
    $pct = [int]$ctx.used_percentage
    $tokens = [int]$ctx.total_input_tokens
    $tok_str = if ($tokens -ge 1000) { "{0:0.0}k" -f ($tokens / 1000.0) } else { "$tokens" }
    $ctx_color = if ($pct -lt 50) { $c.green } elseif ($pct -lt 80) { $c.yellow } else { $c.red }
    $warn = if ($d.exceeds_200k_tokens) { (paint '!' $c.red) } else { '' }
    $parts.Add((paint "ctx ${pct}% ${tok_str}${warn}" $ctx_color))
}

# cost
if ($d.cost.total_cost_usd -gt 0) {
    $parts.Add((paint ('${0:0.00}' -f $d.cost.total_cost_usd) $c.green))
}

# duration (wall-clock)
if ($d.cost.total_duration_ms -gt 0) {
    $sec = [int]($d.cost.total_duration_ms / 1000)
    $h = [int]($sec / 3600); $m = [int](($sec % 3600) / 60); $s = $sec % 60
    $dur = if ($h -gt 0) { "${h}h${m}m" } elseif ($m -gt 0) { "${m}m${s}s" } else { "${s}s" }
    $parts.Add((paint $dur $c.blue))
}

# lines changed
$added = [int]$d.cost.total_lines_added
$removed = [int]$d.cost.total_lines_removed
if (($added + $removed) -gt 0) {
    $parts.Add((paint "+$added" $c.green) + (paint "/-$removed" $c.red))
}

[Console]::Out.Write(($parts -join " $($c.dim)|$($c.reset) "))
