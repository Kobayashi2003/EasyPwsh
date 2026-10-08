<#
.SYNOPSIS
    Initialize fnm and switch Node versions when changing directories.
.NOTES
    https://github.com/Schniz/fnm#powershell
#>

$__fnmCommand = Get-Command fnm -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $__fnmCommand) { return }

# fnm env creates a unique multishell directory for each session. Do not cache
# its output or defer it until the first fnm call: node needs PATH immediately.
try {
    $__fnmHook = Invoke-EasyPwshUtf8Command -FilePath $__fnmCommand.Source -ArgumentList @('env', '--use-on-cd', '--shell', 'powershell')
    if ([string]::IsNullOrWhiteSpace($__fnmHook)) { throw 'fnm env returned an empty initialization script.' }
    Invoke-Expression $__fnmHook
} catch {
    Write-Warning "fnm initialization failed: $($_.Exception.Message)"
}
