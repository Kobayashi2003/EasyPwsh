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
$statusline_shell     = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })
$statusline_command   = "`"$statusline_shell`" -NoLogo -NoProfile -File `"$statusline_script`""

try {
    $settings_file_exists = Test-Path -LiteralPath $claude_settings_file -ErrorAction Stop
    $settings = [PSCustomObject]@{}
    if ($settings_file_exists) {
        $settings_json = Get-Content -LiteralPath $claude_settings_file -Raw -Encoding UTF8 -ErrorAction Stop
        # Null-only files contain no settings to preserve, even when null was written more than once.
        if (-not [string]::IsNullOrWhiteSpace($settings_json) -and $settings_json -cnotmatch '\A\s*null(?:\s+null)*\s*\z') {
            if (-not $settings_json.TrimStart().StartsWith('{')) {
                throw 'Expected a JSON object.'
            }
            $settings = ConvertFrom-Json -InputObject $settings_json -ErrorAction Stop
        }
    }

    $desired = [PSCustomObject]@{
        type            = 'command'
        command         = $statusline_command
        refreshInterval = 30
    }

    $current_json = $settings.statusLine | ConvertTo-Json -Compress
    $desired_json = $desired | ConvertTo-Json -Compress

    if ($current_json -cne $desired_json) {
        $settings | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $desired -Force
        $updated_json = ($settings | ConvertTo-Json -Depth 100 -ErrorAction Stop) + [Environment]::NewLine
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $claude_settings_file))

        # Write the complete JSON before publishing it. Follow user-managed links in place.
        if ($settings_file_exists -and (Get-Item -LiteralPath $claude_settings_file -Force -ErrorAction Stop).LinkType) {
            [IO.File]::WriteAllText($claude_settings_file, $updated_json)
        } else {
            $temp_file = "$claude_settings_file.$([guid]::NewGuid()).tmp"
            try {
                [IO.File]::WriteAllText($temp_file, $updated_json)
                if ($settings_file_exists) {
                    [IO.File]::Replace($temp_file, $claude_settings_file, [NullString]::Value)
                } else {
                    [IO.File]::Move($temp_file, $claude_settings_file)
                }
            } finally {
                [IO.File]::Delete($temp_file)
            }
        }
    }
} catch {
    Write-Warning "Could not configure Claude Code statusLine in '$claude_settings_file'. Check that the file contains a valid JSON object and is writable."
}
#endregion

#region claude skills — symlink EasyPwsh-managed skills into Claude's skills directory
# Skills installed from other people's repos are copied in directly under
# ~/.claude/skills (not managed here); only skills we author ourselves live
# under config\skills and get linked automatically here.
$claude_skills_dir = Join-Path $env:USERPROFILE -ChildPath ".claude\skills"
$claude_skills_src = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "config\skills"

# Skills under config\skills that should NOT be linked into Claude's skills
# directory (e.g. still WIP, or intentionally disabled). Any link previously
# created for a now-excluded skill is removed on the next shell start.
$claude_skills_excluded = @(
    # "some-skill-name"
)

if (Test-Path -LiteralPath $claude_skills_src) {
    Get-ChildItem -LiteralPath $claude_skills_src -Directory | ForEach-Object {
        $link = Join-Path $claude_skills_dir -ChildPath $_.Name
        if ($claude_skills_excluded -contains $_.Name) {
            Remove-ManagedSymlink -Path $link -Target $_.FullName
        } else {
            New-ManagedSymlink -Path $link -Target $_.FullName
        }
    }
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
