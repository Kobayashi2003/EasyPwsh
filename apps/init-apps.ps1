function global:Invoke-EasyPwshUtf8Command {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$FilePath,
          [string[]]$ArgumentList = @(), [hashtable]$Environment = @{})
    function ConvertTo-EasyPwshNativeArgument {
        param([AllowNull()][AllowEmptyString()][string]$Value)
        # Windows argv quoting: double backslashes before quotes and at the end.
        $escaped = [regex]::Replace([string]$Value, '(\\*)"', [Text.RegularExpressions.MatchEvaluator]{
            param($match) $match.Groups[1].Value + $match.Groups[1].Value + '\"'
        })
        '"' + ([regex]::Replace($escaped, '(\\+)$', '$1$1')) + '"'
    }

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $FilePath
    $info.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-EasyPwshNativeArgument $_ }) -join ' ')
    $info.WorkingDirectory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false, $true)
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = $Environment[$key] }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$FilePath exited with code $($process.ExitCode): $errorText" }
        return $output
    } finally { $process.Dispose() }
}

function global:reload-apps {
    # Get-ChildItem (Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "common\*ps1"   ) | ForEach-Object { & $_.FullName }
    & (Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "apps\init-apps.ps1") }

function global:show-apps { $global:APPS_ALIAS | Format-Table }

Get-ChildItem (Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "apps\init-*.ps1"   ) | ForEach-Object {
    if ($_.Name -ne $MyInvocation.MyCommand.Name) {
        if ($global:__INIT_TIMINGS) {
            $__asw = [System.Diagnostics.Stopwatch]::StartNew()
            & $_.FullName
            $global:__INIT_TIMINGS["apps\$($_.Name)"] = $__asw.Elapsed.TotalMilliseconds
        } else {
            & $_.FullName
        }
    }
}

$global:APPS_ALIAS.GetEnumerator() | ForEach-Object { if (Test-Path -Path $_.Value -ErrorAction SilentlyContinue) { Set-Alias -Name $_.Key -Value $_.Value -Scope Global } }