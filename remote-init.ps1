<#
.SYNOPSIS
	Bootstraps EasyPwsh utils for remote, clone-free use.
.DESCRIPTION
	Run this once on a fresh machine (no clone needed). It loads the utils
	manifest and wires up a proxy so that calling any util by name (e.g.
	'get-md5 file.txt') lazily downloads utils/<name>.ps1 from GitHub on
	first use, caches it on disk, and runs it like a local script.

	Two modes control discoverability:

	  Lazy (default)  - defines nothing up front. An unknown command is
	                    intercepted via CommandNotFoundAction, resolved
	                    against the manifest, downloaded, and executed.
	                    Lowest footprint; but Get-Command / tab-completion
	                    won't see a util until its first call.

	  -Discoverable   - defines a lightweight stub function for every util
	                    in the manifest now, so Get-Command and tab-completion
	                    list them immediately. Script bodies are still
	                    downloaded lazily on first call.

	Either way, bodies are run with '& <file> @args' (never dot-sourced /
	iex'd) so a util's own 'exit' terminates the script, not your session.
.PARAMETER Discoverable
	Pre-generate stub functions for all utils (enables tab-completion and
	Get-Command discovery). Falls back to $env:EZ_DISCOVERABLE if unset.
.PARAMETER Ref
	Git ref (commit SHA / tag / branch) to pin all downloads to. Falls back
	to $env:EZ_REF, then 'main'. Prefer a commit SHA for reproducibility.
.EXAMPLE
	# Lazy (default) - simplest, args not required:
	PS> irm https://raw.githubusercontent.com/Kobayashi2003/EasyPwsh/main/remote-init.ps1 | iex
.EXAMPLE
	# Discoverable - pass the switch by materializing the script first:
	PS> & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Kobayashi2003/EasyPwsh/main/remote-init.ps1))) -Discoverable
.EXAMPLE
	# Or via env var when piping to iex:
	PS> $env:EZ_DISCOVERABLE = '1'; irm .../remote-init.ps1 | iex
.LINK
	https://github.com/Kobayashi2003/EasyPwsh
.NOTES
	Author: KOBAYASHI | License: CC0
	Security: this executes remote code. Pin -Ref to a commit SHA you trust.
#>

param(
	[switch]$Discoverable,
	[string]$Ref
)

# --- Resolve options (allow env-var fallback for the 'irm | iex' case) -------
if (-not $PSBoundParameters.ContainsKey('Discoverable') -and $env:EZ_DISCOVERABLE) {
	$Discoverable = $true
}
if (-not $Ref) { $Ref = if ($env:EZ_REF) { $env:EZ_REF } else { 'main' } }

$global:EZ = @{
	Owner    = 'Kobayashi2003'
	Repo     = 'EasyPwsh'
	Ref      = $Ref
}
$global:EZ.RawBase  = "https://raw.githubusercontent.com/$($EZ.Owner)/$($EZ.Repo)/$($EZ.Ref)"
$global:EZ.CacheDir = Join-Path (Join-Path $env:LOCALAPPDATA 'EasyPwsh\cache') $EZ.Ref
New-Item -ItemType Directory -Force -Path $EZ.CacheDir | Out-Null

# --- Manifest: prefer committed manifest.json, fall back to git-trees API ----
function global:Get-EzManifest {
	$cache = Join-Path $global:EZ.CacheDir 'manifest.txt'
	if (Test-Path $cache) {
		return [Collections.Generic.HashSet[string]]@(Get-Content $cache)
	}

	$names = $null
	try {
		$names = (Invoke-RestMethod "$($global:EZ.RawBase)/utils/manifest.json").names
	} catch {
		$url  = "https://api.github.com/repos/$($global:EZ.Owner)/$($global:EZ.Repo)/git/trees/$($global:EZ.Ref)?recursive=1"
		$tree = Invoke-RestMethod $url -Headers @{ 'User-Agent' = 'EasyPwsh' }
		$names = $tree.tree |
			Where-Object { $_.path -like 'utils/*.ps1' -and $_.path -notlike 'utils/*/*' } |
			ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.path) }
	}
	$names | Set-Content $cache
	return [Collections.Generic.HashSet[string]]@($names)
}

# --- Lazy fetch: download a single util to the disk cache, return its path ---
function global:Resolve-EzUtil([string]$Name) {
	$file = Join-Path $global:EZ.CacheDir "$Name.ps1"
	if (-not (Test-Path $file)) {
		Invoke-RestMethod "$($global:EZ.RawBase)/utils/$Name.ps1" -OutFile $file
	}
	return $file
}

$global:EZ.Utils = Get-EzManifest

if ($Discoverable) {
	# Eager stubs: real functions exist now (discoverable / tab-completable),
	# but each downloads its body only on first invocation.
	foreach ($name in $global:EZ.Utils) {
		$body = "`$f = Resolve-EzUtil '$name'; & `$f @args"
		Set-Item "function:global:$name" -Value ([scriptblock]::Create($body))
	}
	Write-Host "✔ EasyPwsh ready - discoverable mode, $($global:EZ.Utils.Count) utils (ref=$($global:EZ.Ref))" -ForegroundColor DarkCyan
} else {
	# Lazy proxy: nothing defined up front. Intercept unknown commands, and on
	# first hit promote the util to a permanent global function (so later calls
	# skip the handler entirely).
	$ExecutionContext.InvokeCommand.CommandNotFoundAction = {
		param($Name, $e)
		if (-not $global:EZ.Utils.Contains($Name)) { return }  # not ours -> normal "not found"
		$body = "`$f = Resolve-EzUtil '$Name'; & `$f @args"
		Set-Item "function:global:$Name" -Value ([scriptblock]::Create($body))
		$e.CommandScriptBlock = (Get-Item "function:global:$Name").ScriptBlock
		$e.StopSearch = $true
	}
	Write-Host "✔ EasyPwsh ready - lazy mode, $($global:EZ.Utils.Count) utils (ref=$($global:EZ.Ref))" -ForegroundColor DarkCyan
}
