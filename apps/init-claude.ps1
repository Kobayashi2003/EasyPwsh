<#
.SYNOPSIS
    Initialize Claude Code statusline.
.NOTES
    https://docs.claude.com/en/docs/claude-code/statusline
#>

#region claude initialize
if (-not (Get-Command 'claude' -ErrorAction SilentlyContinue)) {
    return
}

$claude_settings_file = Join-Path $env:USERPROFILE -ChildPath ".claude\settings.json"
$statusline_script    = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "config\claude\statusline.ps1"
$statusline_command   = "pwsh -NoLogo -NoProfile -File `"$statusline_script`""

if (Test-Path $claude_settings_file) {
    $settings = Get-Content $claude_settings_file -Raw | ConvertFrom-Json
} else {
    New-Item -Path $claude_settings_file -ItemType File -Force | Out-Null
    $settings = [PSCustomObject]@{}
}

$desired = [PSCustomObject]@{
    type    = 'command'
    command = $statusline_command
}

$current_json = if ($settings.PSObject.Properties['statusLine']) {
    $settings.statusLine | ConvertTo-Json -Compress
} else { '' }
$desired_json = $desired | ConvertTo-Json -Compress

if ($current_json -ne $desired_json) {
    $settings | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $desired -Force
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $claude_settings_file -Encoding UTF8
}
#endregion

#region claude proxy wrapper — always run claude through $global:PROXY_ADDRESS
# Resolve the real executable (not this function) so re-sourcing the profile can't recurse.
$global:CLAUDE_EXE_PATH = Get-Command 'claude' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty Source
if ($global:CLAUDE_EXE_PATH) {
    # global: scope is required because init-*.ps1 apps are loaded via '&' (child scope);
    # a plain function would not survive back into the session.
    function global:claude {
        # Route API traffic through the proxy, but keep localhost direct so Claude Code
        # can reach local MCP servers (e.g. Pixso on 127.0.0.1:3667) — otherwise the
        # proxy intercepts them and returns a bare 502.
        $proxyUrl = "http://$($global:PROXY_ADDRESS)"
        $overrides = [ordered]@{
            HTTP_PROXY  = $proxyUrl
            HTTPS_PROXY = $proxyUrl
            ALL_PROXY   = $proxyUrl
            NO_PROXY    = 'localhost,127.0.0.1,::1'
        }
        $names = @($overrides.Keys)
        $saved = @{}
        foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process') }
        try {
            foreach ($n in $names) { Set-Item "Env:$n" $overrides[$n] }
            & $global:CLAUDE_EXE_PATH @args
        } finally {
            foreach ($n in $names) {
                if ($null -eq $saved[$n]) {
                    if (Test-Path "Env:$n") { Remove-Item "Env:$n" }
                } else {
                    Set-Item "Env:$n" $saved[$n]
                }
            }
        }
    }
}
#endregion
