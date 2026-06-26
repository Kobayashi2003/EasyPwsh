<#
.SYNOPSIS
	Builds the utils manifest (utils/manifest.json)
.DESCRIPTION
	This PowerShell script scans the author subfolders (fleschutz/, kobayashi/,
	...) under the utils directory and records, for each *.ps1 script, its name,
	repo-relative path, author (= subfolder), and one-line description (pulled
	from the script's .SYNOPSIS). The manifest is consumed by remote-init.ps1 so
	a fresh machine can discover and fetch utils for lazy/remote invocation -
	without cloning the repository and without hitting the GitHub API. Top-level
	scripts (e.g. this builder) are tooling and excluded.
.PARAMETER utilsDir
	Specifies the utils directory to scan (default is this script's folder)
.EXAMPLE
	PS> ./build-manifest.ps1
	✔️ Wrote manifest with 265 utils to 📄utils/manifest.json
.LINK
	https://github.com/Kobayashi2003/EasyPwsh
.NOTES
	Author: KOBAYASHI | License: CC0
#>

param([string]$utilsDir = "$PSScriptRoot")

function Get-Synopsis([string]$file) {
	$lines = Get-Content -LiteralPath $file
	for ($i = 0; $i -lt $lines.Count; $i++) {
		if ($lines[$i] -match '^\s*\.SYNOPSIS') {
			for ($j = $i + 1; $j -lt $lines.Count; $j++) {
				$t = $lines[$j].Trim()
				if ($t) { return $t }
			}
		}
	}
	return ''
}

try {
	if (-not (Test-Path "$utilsDir" -PathType Container)) { throw "Can't access directory: $utilsDir" }

	# Each immediate subfolder is an author; its *.ps1 files are that author's utils.
	$utils = [ordered]@{}
	foreach ($dir in Get-ChildItem -Path $utilsDir -Directory | Sort-Object Name) {
		foreach ($s in Get-ChildItem -Path $dir.FullName -Filter '*.ps1' -File | Sort-Object Name) {
			$utils[$s.BaseName] = [ordered]@{
				path        = "$($dir.Name)/$($s.Name)"
				author      = $dir.Name
				description = (Get-Synopsis $s.FullName)
			}
		}
	}

	$manifest = [ordered]@{
		generatedAt = (Get-Date).ToUniversalTime().ToString('o')
		count       = $utils.Count
		utils       = $utils
	}

	$outFile = Join-Path $utilsDir 'manifest.json'
	$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $outFile -Encoding utf8

	"✔️ Wrote manifest with $($utils.Count) utils to 📄$outFile"
	exit 0 # success
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
