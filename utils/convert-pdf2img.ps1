<#
.SYNOPSIS
	Converts a PDF into images (one image per page)
.DESCRIPTION
	This PowerShell script converts a PDF into images using ImageMagick (the `magick` CLI).
	For PDF decoding, ImageMagick typically requires Ghostscript to be installed (gswin64c/gs).
.PARAMETER Path
	Path to the input PDF.
.PARAMETER OutDir
	Output directory (default is <pdf-filename> folder next to the PDF).
.PARAMETER Format
	Output image format: png/jpg (default png).
.PARAMETER Density
	Rasterization DPI (default 300). Higher = sharper text, larger files.
.PARAMETER Quality
	JPEG quality 1-100 (only used when Format=jpg; default 92).
.PARAMETER Prefix
	Output filename prefix (default is PDF filename).
.PARAMETER FirstPage
	1-based first page to export (optional).
.PARAMETER LastPage
	1-based last page to export (optional).
.PARAMETER Force
	If set, overwrites existing output images with the same prefix.
.PARAMETER SkipGhostscriptCheck
	If set, does not fail fast when Ghostscript is missing (not recommended on Windows).
.EXAMPLE
	PS> ./convert-pdf2img.ps1 -Path .\doc.pdf
	✔️ Created images: C:\docs\doc\doc-001.png ...
.EXAMPLE
	PS> ./convert-pdf2img.ps1 -Path .\scan.pdf -Format jpg -Quality 95 -Density 300 -FirstPage 1 -LastPage 10 -Force
#>

[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$Path,
	[string]$OutDir = "",
	[ValidateSet('png', 'jpg')]
	[string]$Format = 'png',
	[ValidateRange(36, 1200)]
	[int]$Density = 300,
	[ValidateRange(1, 100)]
	[int]$Quality = 92,
	[string]$Prefix = "",
	[ValidateRange(1, 1000000)]
	[int]$FirstPage = 0,
	[ValidateRange(1, 1000000)]
	[int]$LastPage = 0,
	[switch]$Force,
	[switch]$SkipGhostscriptCheck
)

try {
	$magick = Get-Command -Name 'magick' -ErrorAction SilentlyContinue
	if (-not $magick) { throw "ImageMagick not found. Install it so the 'magick' command is available." }

	$pdfItem = Get-Item -LiteralPath $Path -ErrorAction Stop
	if ($pdfItem.PSIsContainer) { throw "Not a file: $Path" }
	if ($pdfItem.Extension.ToLowerInvariant() -ne '.pdf') { throw "Not a PDF file: $($pdfItem.FullName)" }
	$pdfFull = $pdfItem.FullName

	# PDF decoding generally needs Ghostscript (especially on Windows)
	$gs = Get-Command -Name 'gswin64c','gswin32c','gs' -ErrorAction SilentlyContinue | Select-Object -First 1
	if (-not $gs) {
		if ($SkipGhostscriptCheck) {
			Write-Warning "Ghostscript not found (gswin64c/gs). Continuing anyway due to -SkipGhostscriptCheck."
		} else {
			throw (
				"Ghostscript not found (gswin64c/gs), so ImageMagick cannot render PDFs. " +
				"Install Ghostscript and retry. Suggested installs: " +
				"scoop install ghostscript  |  winget install --id ArtifexSoftware.GhostScript -e  |  choco install ghostscript. " +
				"Then confirm: Get-Command gswin64c"
			)
		}
	}

	$baseName = [System.IO.Path]::GetFileNameWithoutExtension($pdfFull)
	if (-not $Prefix -or $Prefix.Trim().Length -eq 0) { $Prefix = $baseName }

	if (-not $OutDir -or $OutDir.Trim().Length -eq 0) {
		$OutDir = Join-Path -Path $pdfItem.DirectoryName -ChildPath $baseName
	}
	$outDirFull = [System.IO.Path]::GetFullPath($OutDir)
	if (-not (Test-Path -LiteralPath $outDirFull)) {
		New-Item -ItemType Directory -Path $outDirFull -Force | Out-Null
	}

	if ($FirstPage -gt 0 -and $LastPage -gt 0 -and $LastPage -lt $FirstPage) {
		throw "LastPage ($LastPage) must be >= FirstPage ($FirstPage)"
	}

	# ImageMagick page indices are 0-based: input.pdf[0] is page 1
	$inputSpec = $pdfFull
	if ($FirstPage -gt 0 -and $LastPage -gt 0) {
		$inputSpec = "$pdfFull[$($FirstPage - 1)-$($LastPage - 1)]"
	} elseif ($FirstPage -gt 0) {
		$inputSpec = "$pdfFull[$($FirstPage - 1)]"
	} elseif ($LastPage -gt 0) {
		$inputSpec = "$pdfFull[0-$($LastPage - 1)]"
	}

	# Output naming: prefix-001.png (ImageMagick uses %d)
	$outPattern = Join-Path -Path $outDirFull -ChildPath ("$Prefix-%03d.$Format")

	if (-not $Force) {
		$existing = Get-ChildItem -LiteralPath $outDirFull -File -ErrorAction SilentlyContinue |
			Where-Object { $_.Name -like "$Prefix-*.${Format}" }
		if ($existing -and $existing.Count -gt 0) {
			throw "Output images already exist in: $outDirFull (use -Force to overwrite)"
		}
	} else {
		Get-ChildItem -LiteralPath $outDirFull -File -ErrorAction SilentlyContinue |
			Where-Object { $_.Name -like "$Prefix-*.${Format}" } |
			Remove-Item -Force -ErrorAction Stop
	}

	$magickArgs = @()
	$magickArgs += @('-density', $Density)
	$magickArgs += $inputSpec

	# For JPEG, avoid transparent background (PDF pages are opaque but some PDFs can include alpha)
	if ($Format -eq 'jpg') {
		$magickArgs += @('-background', 'white', '-alpha', 'remove', '-alpha', 'off', '-quality', $Quality)
	}

	$magickArgs += $outPattern
	& $magick.Source @magickArgs
	if ($lastExitCode -ne 0) { throw "Executing 'magick' exited with error code $lastExitCode" }

	$created = Get-ChildItem -LiteralPath $outDirFull -File -ErrorAction SilentlyContinue |
		Where-Object { $_.Name -like "$Prefix-*.${Format}" }

	if (-not $created -or $created.Count -eq 0) {
		throw "No output images were created. If this is a PDF-read error, install Ghostscript and retry."
	}

	"✔️ Created images: $outDirFull ($($created.Count) files)"
	exit 0
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
