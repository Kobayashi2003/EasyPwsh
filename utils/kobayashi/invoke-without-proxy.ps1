<#
.SYNOPSIS
    Runs a command with the proxy temporarily disabled, then restores the environment
.DESCRIPTION
    This PowerShell script clears the proxy environment variables (HTTP_PROXY /
    HTTPS_PROXY / ALL_PROXY) for the current process, runs the given command, and then
    restores the previous proxy state. This lets a single command bypass the proxy
    without permanently changing the environment. Because the command runs in the same
    process, child processes such as curl.exe inherit the cleared variables.

    The command can be given either as a bare command line (an executable followed by
    its arguments) or as a scriptblock in braces. The bare form is captured verbatim
    via $args, so the wrapped command's own flags (e.g. -A, -C, -I) do not collide
    with this script's parameters. Use the scriptblock form for pipelines, multiple
    statements, or redirection.
.EXAMPLE
    PS> ./invoke-without-proxy.ps1 code
.EXAMPLE
    PS> ./invoke-without-proxy.ps1 curl.exe -s https://ifconfig.me
.EXAMPLE
    PS> ./invoke-without-proxy.ps1 { git pull; git status }
.NOTES
    Author: KOBAYASHI
#>

$names = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")

# Remember the current process values so we can restore them afterwards.
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }

try {
    if ($args.Count -lt 1) {
        throw "No command given. Provide a command to run, e.g. ./invoke-without-proxy.ps1 code"
    }

    foreach ($name in $names) {
        if (Test-Path "Env:$name") { Remove-Item -Path "Env:$name" }
    }

    Write-Host "⏳ Running command without proxy ..." -ForegroundColor Yellow

    if ($args.Count -eq 1 -and $args[0] -is [scriptblock]) {
        & $args[0]
    } else {
        $exe = $args[0]
        $rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }
        & $exe @rest
    }
    exit $LASTEXITCODE
} catch {
    Write-Host "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])" -ForegroundColor Red
    exit 1
} finally {
    # Restore the previous process values (or leave them removed if there were none).
    foreach ($name in $names) {
        if ($null -ne $saved[$name]) {
            Set-Item -Path "Env:$name" -Value $saved[$name]
        }
    }
}
