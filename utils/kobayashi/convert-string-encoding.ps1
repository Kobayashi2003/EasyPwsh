<#
.SYNOPSIS
    Re-encodes a string from one character encoding to another.
.PARAMETER str
    The string to re-encode.
.PARAMETER encode
    Source encoding (default: GBK).
.PARAMETER decode
    Target encoding (default: Shift_JIS).
.EXAMPLE
    PS> ./exchange-code-str.ps1 "Hello" -encode UTF-8 -decode GBK
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$str,

    [Alias("e")]
    [string]$encode = "GBK",

    [Alias("d")]
    [string]$decode = "Shift_JIS"
)

try {
    $srcEnc = [System.Text.Encoding]::GetEncoding($encode)
    $dstEnc = [System.Text.Encoding]::GetEncoding($decode)
    $bytes  = $srcEnc.GetBytes($str)
    Write-Output $dstEnc.GetString($bytes)
} catch {
    Write-Error $_
    exit 1
}
