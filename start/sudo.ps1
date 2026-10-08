if ((Get-Command 'sudo' -ErrorAction SilentlyContinue) -and ((Get-Command 'sudo').Source -ne 'C:\WINDOWS\system32\sudo.exe')) {
<# .Notes
    https://github.com/sudo-pwsh/sudo-pwsh
#>
    return
}

if (Get-Command 'gsudo' -ErrorAction SilentlyContinue) {
<# .Notes
    https://github.com/gerardog/gsudo
#>
    Set-Alias -Name 'sudo' -Value 'gsudo' -Scope Global -Force
    return
}

function global:sudo {
<#
.SYNOPSIS
    Run a command as sudo

.PARAMETER command
    Command to run
.PARAMETER arguments
    Arguments to pass to the command

.EXAMPLE
    sudo ipconfig
#>

    function New-EasyPwshSudoStartInfo {
        param([Parameter(Mandatory)][string]$Command, [object[]]$Arguments = @(),
              [Parameter(Mandatory)][string]$OutputPath, [Parameter(Mandatory)][string]$ShellPath)
        $parts = @("& '$($Command.Replace("'", "''"))'")
        foreach ($argument in $Arguments) {
            # Parameter names stay tokens; values are serialized, never interpolated code.
            if ($argument -is [string] -and $argument -match '^--?[A-Za-z][A-Za-z0-9_-]*$') {
                $parts += $argument
            } else {
                $xml = [Management.Automation.PSSerializer]::Serialize($argument)
                $data = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($xml))
                $parts += "([Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$data'))))"
            }
        }
        $location = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath.Replace("'", "''")
        $outputLiteral = $OutputPath.Replace("'", "''")
        $commandLiteral = $Command.Replace("'", "''")
        $body = @"
`$ErrorActionPreference = 'Stop'
try {
    Set-Location -LiteralPath '$location'
    `$commandInfo = Get-Command -Name '$commandLiteral' -ErrorAction Stop
    $($parts -join ' ') | Out-File -LiteralPath '$outputLiteral' -Encoding Unicode
    if (`$commandInfo.CommandType -eq 'Application' -and `$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
} catch {
    `$_ | Out-String | Out-File -LiteralPath '$outputLiteral' -Encoding Unicode
    exit 1
}
"@
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $ShellPath
        $info.UseShellExecute = $true
        $info.Verb = 'runas'
        $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $info.Arguments = '-NoLogo -NonInteractive -NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
        return $info
    }

    if ($args.Count -eq 0) { throw 'Usage: sudo <command> [arguments]' }
    $arguments = @($args | Select-Object -Skip 1)
    $tempFile = New-TemporaryFile
    $shellPath = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })
    $process = New-Object Diagnostics.Process
    try {
        $process.StartInfo = New-EasyPwshSudoStartInfo -Command $args[0] -Arguments $arguments -OutputPath $tempFile.FullName -ShellPath $shellPath
        [void]$process.Start()
        $process.WaitForExit()
        $contents = @(Get-Content -LiteralPath $tempFile.FullName)
        if ($process.ExitCode -ne 0) { throw "Elevated command failed ($($process.ExitCode)): $($contents -join [Environment]::NewLine)" }
        return $contents
    } finally {
        $process.Dispose()
        Remove-Item -LiteralPath $tempFile.FullName -Force -ErrorAction SilentlyContinue
    }
}
