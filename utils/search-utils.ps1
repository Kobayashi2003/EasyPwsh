<#
.SYNOPSIS
	Interactive real-time search for utils scripts
.DESCRIPTION
	This PowerShell script provides a debounced, interactive search over all .ps1
	scripts in the utils folder. Results update automatically as you type, and you
	can navigate the list with keyboard shortcuts.

	Controls:
	  Type           - Filter scripts by name
	  Backspace      - Delete last character
	  ↑ / Shift+Tab  - Move selection up
	  ↓ / Tab        - Move selection down
	  ESC            - Clear query (press again to exit without selection)
	  Enter          - Confirm selection and exit
	  Ctrl+C         - Exit without selection
.PARAMETER UtilsPath
	Specifies the path to search (default: same folder as this script)
.PARAMETER DebounceMs
	Debounce delay in milliseconds before refreshing results (default: 150)
.EXAMPLE
	PS> ./search-utils.ps1
.EXAMPLE
	PS> ./search-utils.ps1 -DebounceMs 200
#>

param(
	[string]$UtilsPath = "$PSScriptRoot",
	[int]$DebounceMs = 150
)

# ── Collect scripts ──────────────────────────────────────────────────────────
$scripts = Get-ChildItem -Path $UtilsPath -Filter "*.ps1" -File |
	Select-Object -ExpandProperty BaseName |
	Sort-Object

# ── Helpers ──────────────────────────────────────────────────────────────────
function Get-Filtered {
	param([string]$Query, [string[]]$All)
	if ([string]::IsNullOrWhiteSpace($Query)) { return , $All }
	return , @($All | Where-Object { $_ -like "*$Query*" })
}

function Get-ScrollOffset {
	param([int]$Sel, [int]$Offset, [int]$MaxRows, [int]$Count)
	if ($Count -eq 0)             { return 0 }
	if ($Sel -lt $Offset)         { return $Sel }
	if ($Sel -ge $Offset + $MaxRows) { return $Sel - $MaxRows + 1 }
	return $Offset
}

# ── Render query line only (immediate, no debounce) ─────────────────────────
function Render-QueryLine {
	param([string]$Query)
	$w = [Console]::WindowWidth - 1
	[Console]::SetCursorPosition(0, 2)   # row 0=title 1=divider 2=query
	[Console]::Write("  > ")
	[Console]::ForegroundColor = [ConsoleColor]::White
	[Console]::Write(($Query + " ").PadRight($w - 4))
	[Console]::ResetColor(); [Console]::WriteLine()
}

# ── Render full UI (debounced) ───────────────────────────────────────────────
function Render {
	param([string]$Query, [string[]]$Filtered, [int]$SelIndex, [int]$ScrollOff, [int]$TotalCount)

	$maxRows = [Math]::Max(1, [Console]::WindowHeight - 7)
	# Use width-1 so the cursor never sits exactly at the last column;
	# writing a newline at column $width would carry the active background
	# color into the next line, causing the right-edge colour bleed.
	$w = [Console]::WindowWidth - 1

	[Console]::SetCursorPosition(0, 0)

	# Title
	[Console]::ForegroundColor = [ConsoleColor]::Cyan
	[Console]::Write("  Utils Script Search".PadRight($w))
	[Console]::ResetColor(); [Console]::WriteLine()

	# Divider
	[Console]::ForegroundColor = [ConsoleColor]::DarkGray
	[Console]::Write(("  " + [string]::new([char]0x2500, $w - 4)).PadRight($w))
	[Console]::ResetColor(); [Console]::WriteLine()

	# Query line
	[Console]::Write("  > ")
	[Console]::ForegroundColor = [ConsoleColor]::White
	[Console]::Write(($Query + " ").PadRight($w - 4))
	[Console]::ResetColor(); [Console]::WriteLine()

	# Status line
	$selDisplay = if ($Filtered.Count -gt 0) { $SelIndex + 1 } else { 0 }
	[Console]::ForegroundColor = [ConsoleColor]::DarkGray
	$status = "  $($Filtered.Count)/$TotalCount matched  sel:$selDisplay  |  ↑↓/Tab: navigate  |  ESC: clear  |  Enter: select"
	[Console]::Write($status.PadRight($w))
	[Console]::ResetColor(); [Console]::WriteLine()
	[Console]::WriteLine([string]::new(' ', $w))   # blank separator

	# Result rows
	$endIdx = [Math]::Min($ScrollOff + $maxRows, $Filtered.Count)
	for ($i = $ScrollOff; $i -lt $endIdx; $i++) {
		$item       = $Filtered[$i]
		$isSelected = ($i -eq $SelIndex)

		if ($isSelected) {
			[Console]::BackgroundColor = [ConsoleColor]::DarkCyan
			[Console]::ForegroundColor = [ConsoleColor]::White
			[Console]::Write("  $item".PadRight($w))
			[Console]::ResetColor(); [Console]::WriteLine()
		} elseif ($Query) {
			$idx = $item.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase)
			if ($idx -ge 0) {
				$before  = $item.Substring(0, $idx)
				$match   = $item.Substring($idx, $Query.Length)
				$after   = $item.Substring($idx + $Query.Length)
				# Compute padding based on actual character count, not string concat
				$written = 2 + $before.Length + $Query.Length + $after.Length
				$pad     = [Math]::Max(0, $w - $written)
				[Console]::Write("  $before")
				[Console]::ForegroundColor = [ConsoleColor]::Yellow
				[Console]::Write($match)
				[Console]::ResetColor()
				[Console]::Write($after + [string]::new(' ', $pad))
				[Console]::WriteLine()
			} else {
				[Console]::WriteLine("  $item".PadRight($w))
			}
		} else {
			[Console]::WriteLine("  $item".PadRight($w))
		}
	}

	# Footer: scroll indicator or empty lines to clear leftovers
	$shown = $endIdx - $ScrollOff
	$hiddenBelow = $Filtered.Count - $endIdx
	$hiddenAbove = $ScrollOff

	if ($hiddenBelow -gt 0 -or $hiddenAbove -gt 0) {
		[Console]::ForegroundColor = [ConsoleColor]::DarkGray
		$indicator = "  "
		if ($hiddenAbove -gt 0) { $indicator += "↑$hiddenAbove  " }
		if ($hiddenBelow -gt 0) { $indicator += "↓$hiddenBelow" }
		[Console]::Write($indicator.PadRight($w))
		[Console]::ResetColor(); [Console]::WriteLine()
		$shown++
	}

	# Clear remaining lines from a previous longer list
	for ($i = $shown; $i -le $maxRows; $i++) {
		[Console]::WriteLine([string]::new(' ', $w))
	}
}

# ── State ─────────────────────────────────────────────────────────────────────
$query             = ""
$lastRenderedQuery = $null           # $null forces first render
$debounceDeadline  = [DateTime]::Now
$forceRender       = $false
$running           = $true
$confirmed         = $false
$selIndex          = 0
$scrollOff         = 0
$filtered          = @($scripts)

Clear-Host
[Console]::CursorVisible = $false

try {
	while ($running) {
		$maxRows = [Math]::Max(1, [Console]::WindowHeight - 7)

		if ([Console]::KeyAvailable) {
			$key = [Console]::ReadKey($true)

			switch ($key.Key) {
				'Escape' {
					if ($query.Length -gt 0) {
						$query     = ""
						$selIndex  = 0
						$scrollOff = 0
						Render-QueryLine -Query $query
						$forceRender = $true
					} else {
						$running = $false
					}
				}
				'Backspace' {
					if ($query.Length -gt 0) {
						$query     = $query.Substring(0, $query.Length - 1)
						$selIndex  = 0
						$scrollOff = 0
						Render-QueryLine -Query $query
					}
					$debounceDeadline = [DateTime]::Now.AddMilliseconds($DebounceMs)
				}
				'UpArrow' {
					if ($filtered.Count -gt 0) {
						$selIndex  = ($selIndex - 1 + $filtered.Count) % $filtered.Count
						$scrollOff = Get-ScrollOffset $selIndex $scrollOff $maxRows $filtered.Count
						$forceRender = $true
					}
				}
				'DownArrow' {
					if ($filtered.Count -gt 0) {
						$selIndex  = ($selIndex + 1) % $filtered.Count
						$scrollOff = Get-ScrollOffset $selIndex $scrollOff $maxRows $filtered.Count
						$forceRender = $true
					}
				}
				'Tab' {
					if ($filtered.Count -gt 0) {
						if ($key.Modifiers -band [ConsoleModifiers]::Shift) {
							$selIndex = ($selIndex - 1 + $filtered.Count) % $filtered.Count
						} else {
							$selIndex = ($selIndex + 1) % $filtered.Count
						}
						$scrollOff = Get-ScrollOffset $selIndex $scrollOff $maxRows $filtered.Count
						$forceRender = $true
					}
				}
				'Enter' {
					$confirmed = $true
					$running   = $false
				}
				default {
					$ch = $key.KeyChar
					if ($ch -ne [char]0 -and -not [char]::IsControl($ch)) {
						$query    += $ch
						$selIndex  = 0
						$scrollOff = 0
						Render-QueryLine -Query $query
					}
					$debounceDeadline = [DateTime]::Now.AddMilliseconds($DebounceMs)
				}
			}

			if ($forceRender) {
				if ($query -ne $lastRenderedQuery) {
					$filtered          = Get-Filtered -Query $query -All $scripts
					$lastRenderedQuery = $query
				}
				Render -Query $query -Filtered $filtered -SelIndex $selIndex -ScrollOff $scrollOff -TotalCount $scripts.Count
				$forceRender = $false
			}
		} else {
			# Debounce: render only when typing has paused
			if ($query -ne $lastRenderedQuery -and [DateTime]::Now -ge $debounceDeadline) {
				$filtered          = Get-Filtered -Query $query -All $scripts
				$selIndex          = 0
				$scrollOff         = 0
				Render -Query $query -Filtered $filtered -SelIndex $selIndex -ScrollOff $scrollOff -TotalCount $scripts.Count
				$lastRenderedQuery = $query
			}
			Start-Sleep -Milliseconds 10
		}
	}
} finally {
	[Console]::CursorVisible = $true
	Clear-Host
}

# Output selected script on Enter
if ($confirmed -and $filtered.Count -gt 0) {
	Set-Clipboard $filtered[$selIndex]
	Write-Host $filtered[$selIndex]
}
