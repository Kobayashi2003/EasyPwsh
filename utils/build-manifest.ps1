<#
.SYNOPSIS
	Builds the utils manifest (utils/manifest.json)
.DESCRIPTION
	This PowerShell script scans the top-level *.ps1 scripts in the utils
	directory and writes their base names into utils/manifest.json. The
	manifest is consumed by remote-init.ps1 so a fresh machine can discover
	which utils are available for lazy/remote invocation - without cloning
	the repository and without hitting the GitHub API.
.PARAMETER utilsDir
	Specifies the utils directory to scan (default is this script's folder)
.EXAMPLE
	PS> ./build-manifest.ps1
	✔️ Wrote manifest with 230 utils to 📄utils/manifest.json
.LINK
	https://github.com/Kobayashi2003/EasyPwsh
.NOTES
	Author: KOBAYASHI | License: CC0
#>

param([string]$utilsDir = "$PSScriptRoot")

try {
	if (-not (Test-Path "$utilsDir" -PathType Container)) { throw "Can't access directory: $utilsDir" }

	# Only top-level *.ps1 scripts map to the raw URL utils/<name>.ps1; skip
	# subfolders (e.g. harlequin-postgres) and the manifest builder itself.
	$names = Get-ChildItem -Path $utilsDir -Filter '*.ps1' -File |
		Where-Object { $_.BaseName -ne 'build-manifest' } |
		ForEach-Object { $_.BaseName } |
		Sort-Object

	$manifest = [ordered]@{
		generatedAt = (Get-Date).ToUniversalTime().ToString('o')
		count       = $names.Count
		names       = @($names)
	}

	$outFile = Join-Path $utilsDir 'manifest.json'
	$manifest | ConvertTo-Json -Depth 3 | Set-Content -Path $outFile -Encoding utf8

	"✔️ Wrote manifest with $($names.Count) utils to 📄$outFile"
	exit 0 # success
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
