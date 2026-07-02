<#
.SYNOPSIS
    Removes the proxy environment variables (HTTP_PROXY / HTTPS_PROXY / ALL_PROXY)
.DESCRIPTION
    This PowerShell script clears the proxy environment variables that were set by
    set-proxy.ps1. By default it removes the user variables. Use the -System switch
    to remove the machine-wide variables instead (requires an elevated console).
    The variables are always cleared from the current process as well, so the change
    takes effect immediately in the running session.
.PARAMETER System
    If specified, removes the system (Machine) variables instead of user variables.
    Requires administrator privileges.
.EXAMPLE
    PS> ./unset-proxy.ps1
    ✔️ Proxy environment variables removed (User scope).
.EXAMPLE
    PS> ./unset-proxy.ps1 -System
    ✔️ Proxy environment variables removed (Machine scope).
.NOTES
    Author: KOBAYASHI
#>

param(
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

    foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")) {
        # Remove from the persisted scope (setting to $null deletes the variable)...
        [Environment]::SetEnvironmentVariable($name, $null, $scope)
        # ...and remove from the current process.
        if (Test-Path "Env:$name") { Remove-Item -Path "Env:$name" }
    }

    Write-Host "✔️ Proxy environment variables removed ($($scope) scope)." -ForegroundColor Green
    exit 0 # success
} catch {
    Write-Host "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])" -ForegroundColor Red
    exit 1
}
