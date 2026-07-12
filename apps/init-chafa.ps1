<#
.SYNOPSIS
    Chafa image viewer
.NOTES
    https://github.com/hpjansson/chafa
#>

if (-not (Get-Command 'chafa' -ErrorAction SilentlyContinue)) {
    return
}

function global:view-image { param (

    [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
    [string] $path,

    [Parameter(Mandatory = $false)]
    [switch][alias('u')] $isUrl,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $chafaArgs
)

    $tmp = $null

    try {
        if ($isUrl) {
            # Keep the extension: chafa picks its loader from the file name.
            $extension = [System.IO.Path]::GetExtension(([Uri] $path).AbsolutePath)
            $tmp = "$env:TEMP\$((New-Guid).ToString())$extension"
            Invoke-WebRequest -Uri $path -OutFile $tmp
            $path = $tmp
        }

        # & chafa $path --clear --align 'center,center' --optimize 0
        & chafa $path @chafaArgs
    } finally {
        if ($tmp -and (Test-Path -LiteralPath $tmp)) {
            Remove-Item -LiteralPath $tmp -Force
        }
    }
}