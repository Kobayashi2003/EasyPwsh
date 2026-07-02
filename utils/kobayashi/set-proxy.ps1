<#
.SYNOPSIS
    Sets the proxy environment variables (HTTP_PROXY / HTTPS_PROXY / ALL_PROXY)
.DESCRIPTION
    This PowerShell script sets the proxy environment variables so that tools such
    as curl, git, pip, npm, etc. route their traffic through the given proxy.
    By default the variables are persisted for the current user. Use the -System
    switch to persist them machine-wide instead (requires an elevated console).
    The variables are always applied to the current process as well, so the change
    takes effect immediately in the running session.
.PARAMETER Port
    The proxy port to use (e.g. 7890).
.PARAMETER Address
    The proxy host address. Defaults to 127.0.0.1.
.PARAMETER System
    If specified, persists the variables as system (Machine) variables instead of
    user variables. Requires administrator privileges.
.EXAMPLE
    PS> ./set-proxy.ps1 -Port 7890
    ✔️ Proxy set to http://127.0.0.1:7890 (User scope).
.EXAMPLE
    PS> ./set-proxy.ps1 -Port 7890 -System
    ✔️ Proxy set to http://127.0.0.1:7890 (Machine scope).
.NOTES
    Author: KOBAYASHI
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [int]$Port,

    [string]$Address = "127.0.0.1",

    [switch]$System
)

try {
    $scope = if ($System) { [EnvironmentVariableTarget]::Machine } else { [EnvironmentVariableTarget]::User }

    if ($System) {
        $admin = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
            throw "The -System switch requires an elevated (administrator) console."
        }
    }

    $proxyUrl = "http://$($Address):$Port"

    foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
        # Persist to the chosen scope...
        [Environment]::SetEnvironmentVariable($name, $proxyUrl, $scope)
        # ...and apply to the current process so it takes effect right away.
        Set-Item -Path "Env:$name" -Value $proxyUrl
    }

    Write-Host "✔️ Proxy set to $proxyUrl ($($scope) scope)." -ForegroundColor Green
    exit 0 # success
} catch {
    Write-Host "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])" -ForegroundColor Red
    exit 1
}
