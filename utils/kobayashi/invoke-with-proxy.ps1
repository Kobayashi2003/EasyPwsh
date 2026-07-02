<#
.SYNOPSIS
    Runs a command with the proxy temporarily enabled, then restores the environment
.DESCRIPTION
    This PowerShell script sets the proxy environment variables (HTTP_PROXY /
    HTTPS_PROXY / ALL_PROXY) for the current process, runs the given command, and
    then restores the previous proxy state. This lets a single command go through the
    proxy without permanently changing the environment. Because the command runs in
    the same process, child processes such as curl.exe inherit the temporary variables.

    The command can be given either as a bare command line (an executable followed by
    its arguments) or as a scriptblock in braces. The bare form is captured verbatim
    via $args, so the wrapped command's own flags (e.g. -A, -C, -I) do not collide
    with this script's parameters. Use the scriptblock form for pipelines, multiple
    statements, or redirection.
.PARAMETER Proxy
    The proxy to use, as either a bare port (e.g. 7890, implies 127.0.0.1) or as
    HOST:PORT (e.g. 192.168.1.10:7890). A leading http:// is accepted and ignored.
.EXAMPLE
    PS> ./invoke-with-proxy.ps1 7890 code
.EXAMPLE
    PS> ./invoke-with-proxy.ps1 7890 curl.exe -s https://ifconfig.me
.EXAMPLE
    PS> ./invoke-with-proxy.ps1 192.168.1.10:7890 { git pull; git status }
.NOTES
    Author: KOBAYASHI
#>

param(
    [string]$Proxy
)

$names = @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")

# Remember the current process values so we can restore them afterwards.
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process") }

try {
    if ([string]::IsNullOrWhiteSpace($Proxy)) {
        throw "No proxy given. Provide a port (e.g. 7890) or HOST:PORT as the first argument."
    }
    if ($args.Count -lt 1) {
        throw "No command given. Provide a command to run, e.g. ./invoke-with-proxy.ps1 7890 code"
    }

    # Normalize the proxy into a full URL. Accept 'PORT', 'HOST:PORT' or 'http://HOST:PORT'.
    $p = $Proxy -replace '^https?://', ''
    if ($p -match '^\d+$') {
        $proxyUrl = "http://127.0.0.1:$p"
    } elseif ($p -match '^[^:]+:\d+$') {
        $proxyUrl = "http://$p"
    } else {
        throw "Invalid proxy '$Proxy'. Use a port (e.g. 7890) or HOST:PORT (e.g. 127.0.0.1:7890)."
    }

    foreach ($name in $names) { Set-Item -Path "Env:$name" -Value $proxyUrl }

    Write-Host "⏳ Running command with proxy $proxyUrl ..." -ForegroundColor Yellow

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
    # Restore the previous process values (or remove them if there were none).
    foreach ($name in $names) {
        if ($null -eq $saved[$name]) {
            if (Test-Path "Env:$name") { Remove-Item -Path "Env:$name" }
        } else {
            Set-Item -Path "Env:$name" -Value $saved[$name]
        }
    }
}
