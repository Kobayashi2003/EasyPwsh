<#
.SYNOPSIS
    Text-to-speech utility using SAPI.SpVoice.
.DESCRIPTION
    This script converts text to speech using the Windows SAPI engine.
    It supports speaking text with different voices and can control volume and rate.
.PARAMETER Text
    The text to be spoken.
.PARAMETER Volume
    Voice volume (0-100). Default is 100.
.PARAMETER Rate
    Speech rate (-10 to 10). Default is 0.
.EXAMPLE
    PS> ./Invoke-Speech.ps1 -Text "Hello World"
.EXAMPLE
    PS> ./Invoke-Speech.ps1 -Text "Fast speaking" -Rate 5 -Volume 80
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Text,

    [Parameter()]
    [ValidateRange(0, 100)]
    [int]$Volume = 100,

    [Parameter()]
    [ValidateRange(-10, 10)]
    [int]$Rate = 0
)

try {
    $voice = New-Object -ComObject SAPI.SpVoice

    # Configure voice settings
    $voice.Volume = $Volume
    $voice.Rate = $Rate

    # Get available voices
    $voices = $voice.GetVoices()
    if ($voices.Count -gt 0) {
        Write-Host "Available voices:"
        for ($i = 0; $i -lt $voices.Count; $i++) {
            Write-Host "$i : $($voices.Item($i).GetDescription())"
        }
    }

    # Speak the text
    $voice.Speak($Text)

    # Cleanup
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($voice) | Out-Null

    "✔️ Text spoken successfully"
    exit 0 # success
}
catch {
    Write-Error "Failed to speak text: $_"
    exit 1
}