<#
.SYNOPSIS
	Converts (merges) images into a single PDF in filename order
.DESCRIPTION
	This PowerShell script scans a directory for images, sorts them by filename, and merges them into a single PDF.
	It ONLY uses ImageMagick (the `magick` CLI).
.PARAMETER dir
	Specifies the directory containing images (default is current working directory)
.PARAMETER out
	Specifies the output PDF path (default is <directory-name>.pdf in the same directory)
.PARAMETER recurse
	If set, includes images in subdirectories
.PARAMETER force
	If set, overwrites the output PDF if it already exists
.PARAMETER natural
	If set, sorts files in natural (human) order (e.g. 2 before 10)
.PARAMETER highQuality
	If set, uses higher-quality settings (may increase output file size)
.EXAMPLE
	PS> ./convert-img2pdf.ps1
	✔️ Created PDF: C:\pics\pics.pdf (42 images)
.EXAMPLE
	PS> ./convert-img2pdf.ps1 -dir . -out merged.pdf
.EXAMPLE
	PS> convert-img2pdf -dir D:\scans -recurse -force
#>

param(
	[string]$dir = "$PWD",
	[string]$out = "",
	[switch]$recurse,
	[switch]$force,
	[switch]$natural,
	[switch]$highQuality
)

try {
	$magick = Get-Command -Name 'magick' -ErrorAction SilentlyContinue
	if (-not $magick) { throw "ImageMagick not found. Install it so the 'magick' command is available." }

	$dirItem = Get-Item -LiteralPath $dir -ErrorAction Stop
	if (-not $dirItem.PSIsContainer) { throw "Not a directory: $dir" }
	$dirFull = $dirItem.FullName

	if (-not $out -or $out.Trim().Length -eq 0) {
		$leaf = Split-Path -Path $dirFull -Leaf
		if (-not $leaf) { $leaf = 'output' }
		$out = Join-Path -Path $dirFull -ChildPath ($leaf + '.pdf')
	}
	$outFull = [System.IO.Path]::GetFullPath($out)

	if ((Test-Path -LiteralPath $outFull) -and (-not $force)) {
		throw "Output already exists: $outFull (use -force to overwrite)"
	}

	$exts = @('.jpg', '.jpeg', '.png', '.bmp', '.tif', '.tiff', '.webp')

	function Get-NaturalSortKey([string]$s) {
		if ($null -eq $s) { return '' }
		# Pad numeric runs so that string compare matches natural order
		return ([regex]::Replace($s, '\d+', { param($m) $m.Value.PadLeft(20, '0') }))
	}

	$imgs = Get-ChildItem -LiteralPath $dirFull -File -Recurse:$recurse -ErrorAction Stop |
		Where-Object { $exts -contains $_.Extension.ToLowerInvariant() } |
		Sort-Object -Property @(
			@{ Expression = { if ($natural) { Get-NaturalSortKey $_.Name } else { $_.Name } }; Ascending = $true },
			@{ Expression = { if ($natural) { Get-NaturalSortKey $_.FullName } else { $_.FullName } }; Ascending = $true }
		)

	if (-not $imgs -or $imgs.Count -eq 0) { throw "No images found in: $dirFull" }

	# Use an @filelist to avoid command line length limits
	$tmpList = Join-Path -Path $env:TEMP -ChildPath ("easy-pwsh-img2pdf-" + [Guid]::NewGuid().ToString('N') + ".txt")
	try {
		$imgs | ForEach-Object { '"' + $_.FullName.Replace('"', '""') + '"' } | Set-Content -LiteralPath $tmpList -Encoding UTF8

		if (Test-Path -LiteralPath $outFull) {
			Remove-Item -LiteralPath $outFull -Force -ErrorAction Stop
		}

		$magickArgs = @()
		$magickArgs += ("@" + $tmpList)
		if ($highQuality) {
			# Favor quality over size. Note: this still may re-encode images depending on input types.
			$magickArgs += @('-quality', '100', '-compress', 'Zip', '-units', 'PixelsPerInch', '-density', '300')
		}
		$magickArgs += $outFull
		& $magick.Source @magickArgs
		if ($lastExitCode -ne "0") { throw "Executing 'magick' exited with error code $lastExitCode" }
	} finally {
		if (Test-Path -LiteralPath $tmpList) { Remove-Item -LiteralPath $tmpList -Force -ErrorAction SilentlyContinue }
	}

	"✔️ Created PDF: $outFull ($($imgs.Count) images)"
	exit 0
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
