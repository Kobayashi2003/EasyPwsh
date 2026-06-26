<#
.SYNOPSIS
    Re-encodes a file from one character encoding to another.
.PARAMETER path
    Path to the file to process.
.PARAMETER encode
    Source encoding (default: GBK).
.PARAMETER decode
    Target encoding (default: Shift_JIS).
.PARAMETER cover
    Overwrite the original file with re-encoded content.
.PARAMETER backup
    Backup the original file before overwriting (requires -cover).
.EXAMPLE
    PS> ./exchange-code.ps1 "file.txt" -encode GBK -decode UTF-8 -cover -backup
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$path,

    [Alias("e")]
    [string]$encode = "GBK",

    [Alias("d")]
    [string]$decode = "Shift_JIS",

    [Alias("c")]
    [switch]$cover,

    [Alias("b")]
    [switch]$backup
)

if ($backup -and -not $cover) {
    Write-Error "exchange-code: -backup requires -cover"
    exit 1
}
if (-not (Test-Path $path)) {
    Write-Error "exchange-code: file not found: $path"
    exit 1
}
if ((Get-Item $path).PSIsContainer) {
    Write-Error "exchange-code: path is a directory: $path"
    exit 1
}

try {
    $srcEnc = [System.Text.Encoding]::GetEncoding($encode)
    $dstEnc = [System.Text.Encoding]::GetEncoding($decode)

    $reader  = [System.IO.StreamReader]::new($path, $srcEnc)
    $content = $reader.ReadToEnd()
    $reader.Close()

    $bytes  = $srcEnc.GetBytes($content)
    $result = $dstEnc.GetString($bytes)

    if ($cover) {
        if ($backup) { Copy-Item $path "$path.bak" }
        $writer = [System.IO.StreamWriter]::new($path, $false, $dstEnc)
        $writer.Write($result)
        $writer.Close()
        Write-Output "Covered"
    } else {
        Write-Output $result
    }
} catch {
    Write-Error $_
    exit 1
}
