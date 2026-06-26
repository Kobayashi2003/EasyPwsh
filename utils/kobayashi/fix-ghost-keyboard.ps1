<#
.SYNOPSIS
	Fixes the persistent "Ghost" English (en-US) keyboard layout on Windows 11.
.DESCRIPTION
	This PowerShell script forces the addition and subsequent removal of the
	US English language pack to clear the persistent "ENG" icon from the
	taskbar without requiring a logout.
.EXAMPLE
	PS> ./fix-ghost-keyboard.ps1
#>

try {
	$StopWatch = [system.diagnostics.stopwatch]::startNew()

	"⏳ Step 1 - Fetching current user language list..."
	$List = Get-WinUserLanguageList

	# Check if en-US exists; if not, add it to trigger a system refresh
	if (-not ($List.LanguageTag -contains "en-US")) {
		"➕ Step 2 - Injecting English (US) to trigger layout refresh..."
		$List.Add("en-US")
		Set-WinUserLanguageList $List -Force
		"Waiting for system to register changes..."
		Start-Sleep -Seconds 1
	}

	"🧹 Step 3 - Removing English (US) from the list..."
	# Re-fetch the list to ensure synchronization
	$List = Get-WinUserLanguageList
	$Target = $List | Where-Object LanguageTag -eq "en-US"
	if ($Target) {
		$List.Remove($Target)
		Set-WinUserLanguageList $List -Force
		"✔️ US English layout has been purged."
	} else {
		"ℹ️ US English not found in list, no removal needed."
	}

	[int]$Elapsed = $StopWatch.Elapsed.TotalSeconds
	"✨ Task completed successfully in $Elapsed sec. The 'ENG' icon should be gone."
	exit 0 # success
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}
