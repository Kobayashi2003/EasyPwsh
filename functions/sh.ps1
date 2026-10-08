function sh {
<#
.SYNOPSIS
    This is an alias for powershell
.EXAMPLE
    PS> sh -c "Get-ChildItem | Format-Table Mode, Owner, Length, LastWriteTime, Name"
#>
    $shellPath = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })
    & $shellPath @args
}