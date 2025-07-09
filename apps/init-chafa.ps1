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

    if ($isUrl) {
        $tmp = "$env:TEMP\$((New-Guid).ToString())"
        Invoke-WebRequest -Uri $path -OutFile $tmp
        $path = $tmp
    }

    # & chafa $path --clear --align 'center,center' --optimize 0
    & chafa $path @chafaArgs

    if ($isUrl) {
        Remove-Item $path
    }
}