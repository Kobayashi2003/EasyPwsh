function admin {
    if ($args.Count -gt 0) {
        $argList = $args -join ' '
        $shellPath = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })
        Start-Process wt -Verb runAs -ArgumentList "`"$shellPath`" -NoExit -Command $argList"
    } else {
        Start-Process wt -Verb runAs
    }
}

Set-Alias -Name su -Value admin