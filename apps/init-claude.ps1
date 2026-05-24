<#
.SYNOPSIS
    Initialize Claude Code statusline.
.NOTES
    https://docs.claude.com/en/docs/claude-code/statusline
#>

#region claude initialize
if (Get-Command 'claude' -ErrorAction SilentlyContinue) {

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
}
#endregion
