<#
.SYNOPSIS
	Lists direct child item sizes and file counts
.DESCRIPTION
	This PowerShell script lists the total size of each direct child item (files and folders) in the specified directory.
	For folders, it also displays the total file count within them.
.PARAMETER Path
	Specifies the path to the directory to analyze (default is current directory)
.PARAMETER SortBy
	Specifies how to sort results: Size (default), Name, or Type
.PARAMETER Descending
	If set, sorts in descending order (largest first for Size)
.PARAMETER FileOnly
	If set, lists only files in the direct children (mutually exclusive with -DirectoryOnly)
.PARAMETER DirectoryOnly
	If set, lists only directories in the direct children (mutually exclusive with -FileOnly)
.PARAMETER NameWidth
	Specifies the output width for the Name column. If 0 (default), it is auto-calculated from console width.
.EXAMPLE
	PS> ./list-items-size.ps1
	📊 Folder Sizes in D:\Projects

	apps\          2.4MB    47 files
	config\        856KB    23 files
	README.md      12KB
	easy-pwsh.ps1  3KB

	Total: 4 items, 3.3MB
.EXAMPLE
	PS> ./list-items-size.ps1 -Path C:\Data -SortBy Size -Descending
#>


[CmdletBinding(DefaultParameterSetName = 'All')]
param(
	[string]$Path = "$PWD",
	[ValidateSet('Size', 'Name', 'Type')]
	[string]$SortBy = 'Size',
	[switch]$Descending,
	[int]$NameWidth = 0,
	[Parameter(ParameterSetName = 'FileOnly')]
	[switch]$FileOnly,
	[Parameter(ParameterSetName = 'DirectoryOnly')]
	[switch]$DirectoryOnly
)

function Bytes2String([int64]$bytes) {
	if ($bytes -lt 1000) { return "$bytes bytes" }
	$bytes /= 1000.0
	if ($bytes -lt 1000) { return "{0:N1}KB" -f $bytes }
	$bytes /= 1000.0
	if ($bytes -lt 1000) { return "{0:N1}MB" -f $bytes }
	$bytes /= 1000.0
	if ($bytes -lt 1000) { return "{0:N1}GB" -f $bytes }
	$bytes /= 1000.0
	return "{0:N1}TB" -f $bytes
}

function Get-FolderSize([string]$folderPath) {
	$size = 0
	$fileCount = 0
	try {
		$items = Get-ChildItem -LiteralPath $folderPath -Recurse -File -ErrorAction SilentlyContinue
		foreach ($item in $items) {
			$size += $item.Length
			$fileCount++
		}
	} catch {
		# Ignore access denied errors
	}
	return @{
		Size = $size
		FileCount = $fileCount
	}
}

function ConvertTo-NaturalSortKey([string]$text) {
	if ($null -eq $text) { return '' }
	# Natural sort via padding number runs so "file2" < "file10".
	# Use a large fixed width to cover common cases.
	return [regex]::Replace($text.ToLowerInvariant(), '\d+', {
		param($m)
		return $m.Value.PadLeft(20, '0')
	})
}

function Get-ConsoleWidth {
	try {
		$rawUi = $Host.UI.RawUI
		if ($null -ne $rawUi -and $null -ne $rawUi.WindowSize -and $rawUi.WindowSize.Width -gt 0) {
			return [int]$rawUi.WindowSize.Width
		}
	} catch {
	}
	return 120
}

function Test-WideCodePoint([int]$codePoint) {
	# Heuristic: treat common East Asian wide/fullwidth blocks as width=2.
	# This keeps alignment correct in typical Windows Terminal/ConHost monospace fonts.
	return (
		($codePoint -ge 0x1100 -and $codePoint -le 0x115F) -or  # Hangul Jamo init.
		($codePoint -ge 0x2329 -and $codePoint -le 0x232A) -or
		($codePoint -ge 0x2E80 -and $codePoint -le 0xA4CF) -or  # CJK Radicals..Yi
		($codePoint -ge 0xAC00 -and $codePoint -le 0xD7A3) -or  # Hangul Syllables
		($codePoint -ge 0xF900 -and $codePoint -le 0xFAFF) -or  # CJK Compatibility Ideographs
		($codePoint -ge 0xFE10 -and $codePoint -le 0xFE19) -or  # Vertical forms
		($codePoint -ge 0xFE30 -and $codePoint -le 0xFE6F) -or  # CJK Compatibility Forms
		($codePoint -ge 0xFF00 -and $codePoint -le 0xFF60) -or  # Fullwidth forms
		($codePoint -ge 0xFFE0 -and $codePoint -le 0xFFE6) -or
		($codePoint -ge 0x3000 -and $codePoint -le 0x303F) -or  # CJK Symbols & Punctuation
		($codePoint -ge 0x3040 -and $codePoint -le 0x30FF) -or  # Hiragana/Katakana
		($codePoint -ge 0x31C0 -and $codePoint -le 0x31EF) -or
		($codePoint -ge 0x1F300 -and $codePoint -le 0x1FAFF)     # Many emoji blocks (usually width 2)
	)
}

function Get-TextDisplayWidth([string]$text) {
	if ($null -eq $text -or $text.Length -eq 0) { return 0 }
	[int]$width = 0
	foreach ($r in $text.EnumerateRunes()) {
		$cp = $r.Value
		if (Test-WideCodePoint $cp) {
			$width += 2
		} else {
			$width += 1
		}
	}
	return $width
}

function Take-TextByDisplayWidth([string]$text, [int]$maxWidth) {
	if ($null -eq $text) { return '' }
	if ($maxWidth -le 0) { return '' }
	$sb = New-Object System.Text.StringBuilder
	[int]$used = 0
	foreach ($r in $text.EnumerateRunes()) {
		$cp = $r.Value
		$w = if (Test-WideCodePoint $cp) { 2 } else { 1 }
		if ($used + $w -gt $maxWidth) { break }
		[void]$sb.Append($r.ToString())
		$used += $w
	}
	return $sb.ToString()
}

function Truncate-TextRightByDisplayWidth([string]$text, [int]$maxWidth) {
	if ($null -eq $text) { return '' }
	if ($maxWidth -le 0) { return $text }
	if ((Get-TextDisplayWidth $text) -le $maxWidth) { return $text }
	if ($maxWidth -le 3) { return (Take-TextByDisplayWidth $text $maxWidth) }
	return ((Take-TextByDisplayWidth $text ($maxWidth - 3)) + '...')
}

function PadRight-ByDisplayWidth([string]$text, [int]$targetWidth) {
	if ($null -eq $text) { $text = '' }
	if ($targetWidth -le 0) { return $text }
	$current = Get-TextDisplayWidth $text
	if ($current -ge $targetWidth) { return $text }
	return ($text + (' ' * ($targetWidth - $current)))
}

try {
	$pathItem = Get-Item -LiteralPath $Path -ErrorAction Stop
	if (-not $pathItem.PSIsContainer) {
		throw "Not a directory: $Path"
	}

	Write-Host "📊 Folder Sizes in $($pathItem.FullName)" -ForegroundColor Cyan
	Write-Host ""

	$items = Get-ChildItem -LiteralPath $pathItem.FullName -ErrorAction Stop
	if ($PSCmdlet.ParameterSetName -eq 'FileOnly') {
		$items = $items | Where-Object { -not $_.PSIsContainer }
	} elseif ($PSCmdlet.ParameterSetName -eq 'DirectoryOnly') {
		$items = $items | Where-Object { $_.PSIsContainer }
	}

	$results = @()
	[int64]$totalSize = 0
	[int]$totalCount = 0

	foreach ($item in $items) {
		if ($item.PSIsContainer) {
			$stats = Get-FolderSize $item.FullName
			$results += [PSCustomObject]@{
				Name = $item.Name + "\"
				Size = $stats.Size
				FileCount = $stats.FileCount
				IsFolder = $true
				DisplaySize = Bytes2String $stats.Size
				SortKeyName = ConvertTo-NaturalSortKey ($item.Name + "\")
			}
			$totalSize += $stats.Size
		} else {
			$results += [PSCustomObject]@{
				Name = $item.Name
				Size = $item.Length
				FileCount = 0
				IsFolder = $false
				DisplaySize = Bytes2String $item.Length
				SortKeyName = ConvertTo-NaturalSortKey $item.Name
			}
			$totalSize += $item.Length
		}
		$totalCount++
	}

	# Sort results
	switch ($SortBy) {
		'Size' {
			if ($Descending) {
				$results = $results | Sort-Object -Property Size, SortKeyName -Descending
			} else {
				$results = $results | Sort-Object -Property Size, SortKeyName
			}
		}
		'Name' {
			if ($Descending) {
				$results = $results | Sort-Object -Property SortKeyName -Descending
			} else {
				$results = $results | Sort-Object -Property SortKeyName
			}
		}
		'Type' {
			# Folders first, then files
			if ($Descending) {
				$results = $results | Sort-Object -Property IsFolder, SortKeyName -Descending
			} else {
				# IsFolder:$true first
				$results = $results | Sort-Object -Property @{ Expression = { $_.IsFolder }; Descending = $true }, SortKeyName
			}
		}
	}

	# Display results
	$minNameWidth = 20
	$sizeWidth = 10
	$filesWidth = 10
	$spacingWidth = 2
	$headerExtraWidth = ($spacingWidth * 2) + $sizeWidth + $filesWidth

	$consoleWidth = Get-ConsoleWidth
	$computedNameWidth = [Math]::Max($minNameWidth, $consoleWidth - $headerExtraWidth)
	$nameWidthEffective = if ($NameWidth -gt 0) { [Math]::Max($minNameWidth, $NameWidth) } else { $computedNameWidth }

	# Header
	$headerName = 'Name'.PadRight($nameWidthEffective)
	$headerSize = 'Size'.PadLeft($sizeWidth)
	$headerFiles = 'Files'.PadLeft($filesWidth)
	Write-Host ($headerName + (' ' * $spacingWidth) + $headerSize + (' ' * $spacingWidth) + $headerFiles) -ForegroundColor DarkCyan
	Write-Host (('-' * $nameWidthEffective) + (' ' * $spacingWidth) + ('-' * $sizeWidth) + (' ' * $spacingWidth) + ('-' * $filesWidth)) -ForegroundColor DarkGray

	foreach ($result in $results) {
		$nameOut = Truncate-TextRightByDisplayWidth $result.Name $nameWidthEffective
		$namePadded = PadRight-ByDisplayWidth $nameOut $nameWidthEffective
		$sizePadded = $result.DisplaySize.PadLeft($sizeWidth)
		$filesOut = if ($result.IsFolder) { "$($result.FileCount)" } else { '' }
		$filesPadded = $filesOut.PadLeft($filesWidth)

		if ($result.IsFolder) {
			Write-Host $namePadded -NoNewline -ForegroundColor Yellow
			Write-Host ((' ' * $spacingWidth) + $sizePadded) -NoNewline -ForegroundColor Green
			Write-Host ((' ' * $spacingWidth) + $filesPadded) -ForegroundColor DarkGray
		} else {
			Write-Host $namePadded -NoNewline
			Write-Host ((' ' * $spacingWidth) + $sizePadded) -NoNewline -ForegroundColor Green
			Write-Host ((' ' * $spacingWidth) + $filesPadded)
		}
	}

	Write-Host ""
	Write-Host "Total: $totalCount items, $(Bytes2String $totalSize)" -ForegroundColor Cyan
	exit 0
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
