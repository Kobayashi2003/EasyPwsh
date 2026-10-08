<#
.SYNOPSIS
    Initialize easy-pwsh
.PARAMETER help
    -h, --help     Show this help message and exit
.PARAMETER version
    -v, --version  Show version information and exit
.PARAMETER init
    -i, --init     Initialize easy-pwsh
.EXAMPLE
    [Admin] PS C:\> easy-pwsh -i
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param (
    [Parameter(ParameterSetName = 'Help')]
    [Alias('h')] [switch] $Help,

    [Parameter(ParameterSetName = 'Version')]
    [Alias('v')] [switch] $Version,

    [Parameter(ParameterSetName = 'Init')]
    [Alias('i')] [switch] $Init,

    [Parameter(ParameterSetName = 'Init')]
    [string] $ProfileEncoding = 'Auto',

    [Parameter(ParameterSetName = 'Run')]
    [Alias('r')] [switch] $Run)


Write-Host "__   __   __                                                        _           __   __   __"    -ForegroundColor DarkCyan
Write-Host "\ \  \ \  \ \      ___   __ _  ___  _   _     _ __  __      __ ___ | |__       / /  / /  / /"    -ForegroundColor DarkCyan
Write-Host " \ \  \ \  \ \    / _ \ / _`` |/ __|| | | |   | '_ \ \ \ /\ / // __|| '_ \     / /  / /  / /"    -ForegroundColor DarkCyan
Write-Host " / /  / /  / /   |  __/| (_| |\__ \| |_| |   | |_) | \ V  V / \__ \| | | |    \ \  \ \  \ \ "    -ForegroundColor DarkCyan
Write-Host "/_/  /_/  /_/     \___| \__,_||___/ \__, |   | .__/   \_/\_/  |___/|_| |_|     \_\  \_\  \_\"    -ForegroundColor DarkCyan
Write-Host "                                    |___/    |_|                                            "    -ForegroundColor DarkCyan


if ($PSCmdlet.ParameterSetName -eq 'Default' -or $PSCmdlet.ParameterSetName -eq 'Help') {
    Write-Host "Usage: easy-pwsh [-h] [-v] [-i] [-r]"
    Write-Host "  -h, --help     Show this help message and exit"
    Write-Host "  -v, --version  Show version information and exit"
    Write-Host "  -i, --init     Initialize easy-pwsh (-ProfileEncoding UTF8 or ANSI for BOM-less Unicode profiles)"
    Write-Host "  -r, --run      Run easy-pwsh"
    return
}

if ($Version) {
    Write-Host "Version: 1.0.0" -ForegroundColor DarkBlue
    return
}

if ($Init) {

    $current_script_dir = Split-Path $MyInvocation.MyCommand.Definition

    function Set-EasyPwshProfileStartup {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$Path,
              [Parameter(Mandatory)][string]$InitPath,
              [string]$SourceEncoding = 'Auto')

        $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $exists = [IO.File]::Exists($Path)
        $original = if ($exists) { [IO.File]::ReadAllBytes($Path) } else { [byte[]]@() }
        $hasBom = ($original.Length -ge 3 -and $original[0] -eq 0xEF -and $original[1] -eq 0xBB -and $original[2] -eq 0xBF) -or
            ($original.Length -ge 2 -and (($original[0] -eq 0xFF -and $original[1] -eq 0xFE) -or ($original[0] -eq 0xFE -and $original[1] -eq 0xFF))) -or
            ($original.Length -ge 4 -and $original[0] -eq 0 -and $original[1] -eq 0 -and $original[2] -eq 0xFE -and $original[3] -eq 0xFF)
        $encoding = [Text.UTF8Encoding]::new($false, $true)
        if (-not $hasBom) {
            if ($SourceEncoding -eq 'Auto') {
                if (@($original | Where-Object { $_ -ge 0x80 }).Count) {
                    throw 'BOM-less non-ASCII profile has ambiguous encoding. Specify -ProfileEncoding UTF8, ANSI, or a code page name. Original file is unchanged.'
                }
            } elseif ($SourceEncoding -eq 'ANSI') {
                $codePage = [int](Get-ItemPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name ACP)
                $encoding = [Text.Encoding]::GetEncoding($codePage)
            } elseif ($SourceEncoding -notin @('UTF8', 'UTF-8')) {
                $encoding = [Text.Encoding]::GetEncoding($SourceEncoding)
            }
        }
        $text = if ($exists) { [IO.File]::ReadAllText($Path, $encoding) } else { '' }
        $startup = ". '$($InitPath.Replace("'", "''"))'"
        $legacyPattern = '(?m)^[ \t]*' + [regex]::Escape(". $InitPath") + '\r?$'
        $text = [regex]::Replace($text, $legacyPattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $startup })
        if ($text -notmatch ('(?m)^[ \t]*' + [regex]::Escape($startup) + '[ \t]*\r?$')) {
            $text += [Environment]::NewLine + $startup + [Environment]::NewLine
        }
        $utf8 = [Text.UTF8Encoding]::new($true)
        [byte[]]$updated = $utf8.GetPreamble() + $utf8.GetBytes($text)
        if ([Convert]::ToBase64String($original) -eq [Convert]::ToBase64String($updated)) {
            return [pscustomobject]@{ Changed = $false; BackupPath = $null }
        }
        $parent = [IO.Path]::GetDirectoryName($Path)
        if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
        $backup = $null
        if ($exists) {
            $backup = $Path + '.bak-' + [guid]::NewGuid().ToString('N')
            [IO.File]::Copy($Path, $backup, $false)
            Write-Verbose "Original profile backed up to $backup"
        }
        [IO.File]::WriteAllBytes($Path, $updated)
        return [pscustomobject]@{ Changed = $true; BackupPath = $backup }
    }
    $profileUpdate = Set-EasyPwshProfileStartup -Path $profile -InitPath (Join-Path $current_script_dir 'core\init.ps1') -SourceEncoding $ProfileEncoding
    if ($profileUpdate.BackupPath) { Write-Host "Profile backup: $($profileUpdate.BackupPath)" }

    if (-not ($env:PSModulePath -like "*$current_script_dir\downloads\Modules*")) {
        [Environment]::SetEnvironmentVariable('PSModulePath', "$current_script_dir\downloads\Modules;$env:PSModulePath", 'User') }

    . $profile

    return
}

if ($Run) {
    $current_script_dir = Split-Path $MyInvocation.MyCommand.Definition
    . $(Join-Path -Path $current_script_dir -ChildPath 'core\init.ps1')
}
