<#
.SYNOPSIS
    Claude Code statusline renderer.
.DESCRIPTION
    Reads the JSON payload Claude Code writes to stdin and prints a 2-line status,
    each line grouping related fields into space-joined clusters, clusters
    separated by a dim "|" — so category boundaries read at a glance:
      1. location — [model] badges dir (branch*) worktree  |  repo PR  |  «session name»
      2. usage    — cost duration +/-lines  |  context bar/tokens  |  5h  |  7d
                     (5h/7d are plan rate limits, so /usage is rarely needed)
.NOTES
    Payload schema: https://code.claude.com/docs/en/statusline
#>

$ErrorActionPreference = 'SilentlyContinue'

[Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

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

# color by percentage: <50 green, <80 yellow, else red
function pctColor($pct) {
    if ($pct -lt 50) { $c.green } elseif ($pct -lt 80) { $c.yellow } else { $c.red }
}

# filled/empty block bar
function bar($pct, $width = 10) {
    $filled = [Math]::Round(($pct / 100) * $width)
    if ($filled -gt $width) { $filled = $width }
    if ($filled -lt 0) { $filled = 0 }
    ('█' * $filled) + ('░' * ($width - $filled))
}

# [int] rounds a double (banker's rounding) instead of truncating, so a
# day/hour/minute breakdown built from [int](secs / unit) silently rounds up
# (e.g. 6d13h shows as 7d13h). Math.Floor gives the true integer quotient.
function idiv($a, $b) { [int64][Math]::Floor($a / $b) }

# "resets in" countdown from a unix-epoch-seconds timestamp
function countdown($resetsAt) {
    if (-not $resetsAt) { return $null }
    $secs = [int64]$resetsAt - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($secs -le 0) { return 'now' }
    $days = idiv $secs 86400; $hrs = idiv ($secs % 86400) 3600; $mins = idiv ($secs % 3600) 60
    if ($days -gt 0) { "${days}d${hrs}h" } elseif ($hrs -gt 0) { "${hrs}h${mins}m" } else { "${mins}m" }
}

# join non-empty items tightly (same cluster)
function cluster($items) { (@($items) | Where-Object { $_ }) -join ' ' }
# join non-empty clusters with the category separator
$sep = " $($c.dim)|$($c.reset) "
function assembleLine($clusters) { (@($clusters) | Where-Object { $_ }) -join $sep }

# ============================================================
# Line 1 — location: where (model + badges + dir + branch + worktree) + remote + session
# ============================================================
$modelPart = if ($d.model.display_name) { paint "[$($d.model.display_name)]" $c.cyan }

$badges = New-Object System.Collections.Generic.List[string]
if ($d.effort.level) { $badges.Add("🧠$($d.effort.level)") }
if ($d.thinking.enabled) { $badges.Add('💭') }
if ($d.fast_mode) { $badges.Add('⚡fast') }
$badgesPart = if ($badges.Count -gt 0) { paint ($badges -join ' ') $c.dim }

$cwd = if ($d.workspace.current_dir) { $d.workspace.current_dir } else { $d.cwd }
$dirPart = if ($cwd) { paint (Split-Path -Leaf $cwd) $c.yellow }

$branchPart = $null
if ($cwd -and (Test-Path $cwd)) {
    Push-Location -Path $cwd
    try {
        $branch = (git symbolic-ref --short HEAD 2>$null)
        if ($branch) {
            $dirty = if ((git status --porcelain 2>$null)) { '*' } else { '' }
            $branchPart = paint "($($branch.Trim())$dirty)" $c.magenta
        }
    } finally { Pop-Location }
}

$worktreePart = if ($d.workspace.git_worktree) { paint "🌲$($d.workspace.git_worktree)" $c.blue }

$repoPart = if ($d.workspace.repo.owner -and $d.workspace.repo.name) {
    paint "$($d.workspace.repo.owner)/$($d.workspace.repo.name)" $c.dim
}

$prPart = $null
if ($d.pr.number) {
    $review = if ($d.pr.review_state) { " $($d.pr.review_state)" } else { '' }
    $prColor = switch ($d.pr.review_state) {
        'approved'          { $c.green }
        'changes_requested' { $c.red }
        default             { $c.dim }
    }
    $prPart = paint "PR#$($d.pr.number)$review" $prColor
}

$sessionPart = if ($d.session_name) { paint "«$($d.session_name)»" $c.dim }

$where  = cluster @($modelPart, $badgesPart, $dirPart, $branchPart, $worktreePart)
$remote = cluster @($repoPart, $prPart)
$l1 = assembleLine @($where, $remote, $sessionPart)

# ============================================================
# Line 2 — usage: cost/duration/diff | context | 5h | 7d
# ============================================================
$contextPart = $null
$ctx = $d.context_window
if ($ctx -and $null -ne $ctx.used_percentage) {
    $pct = [int]$ctx.used_percentage
    $tokens = [int]$ctx.total_input_tokens
    $size = if ($ctx.context_window_size) { [int]$ctx.context_window_size } else { 200000 }
    $tokStr = if ($tokens -ge 1000) { "{0:0.0}k" -f ($tokens / 1000.0) } else { "$tokens" }
    $sizeStr = if ($size -ge 1000) { "{0:0}k" -f ($size / 1000.0) } else { "$size" }
    $color = pctColor $pct
    $warn = if ($d.exceeds_200k_tokens) { (paint ' !200k' $c.red) } else { '' }
    $contextPart = (paint (bar $pct) $color) + (paint " ${pct}%" $color) + (paint " ${tokStr}/${sizeStr}$warn" $c.dim)
}

$costPart = if ($d.cost.total_cost_usd -gt 0) { paint ('${0:0.00}' -f $d.cost.total_cost_usd) $c.green }

$durationPart = $null
if ($d.cost.total_duration_ms -gt 0) {
    $sec = idiv $d.cost.total_duration_ms 1000
    $h = idiv $sec 3600; $m = idiv ($sec % 3600) 60; $s = $sec % 60
    $dur = if ($h -gt 0) { "${h}h${m}m" } elseif ($m -gt 0) { "${m}m${s}s" } else { "${s}s" }
    $durationPart = paint $dur $c.blue
}

$added = [int]$d.cost.total_lines_added
$removed = [int]$d.cost.total_lines_removed
$diffPart = if (($added + $removed) -gt 0) { (paint "+$added" $c.green) + (paint "/-$removed" $c.red) }

$usage = cluster @($costPart, $durationPart, $diffPart)

# 5h / 7d plan rate limits — each its own top-level segment
$ratePartsByWindow = @{}
foreach ($window in @(@{ key = 'five_hour'; label = '5h' }, @{ key = 'seven_day'; label = '7d' })) {
    $w = $d.rate_limits.($window.key)
    if ($w -and $null -ne $w.used_percentage) {
        $pct = [int][Math]::Round($w.used_percentage)
        $color = pctColor $pct
        $reset = countdown $w.resets_at
        $resetStr = if ($reset) { (paint " ↻$reset" $c.dim) } else { '' }
        $ratePartsByWindow[$window.label] = (paint "$($window.label) $(bar $pct 8) ${pct}%" $color) + $resetStr
    }
}

$l2 = assembleLine @($usage, $contextPart, $ratePartsByWindow['5h'], $ratePartsByWindow['7d'])

# --- assemble ---
$lines = @($l1, $l2) | Where-Object { $_ }
[Console]::Out.Write(($lines -join "`n"))
