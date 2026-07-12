function global:check-module {
<#
.SYNOPSIS
    Check if module is installed, installing it when no local version satisfies
    the constraint.

.PARAMETER name
    Name of the module
.PARAMETER version
    Version constraint of the module

.EXAMPLE
    check-module -name Terminal-Icons
.EXAMPLE
    check-module -name PSReadLine -version '==2.3.4'
    check-module -name PSReadLine -version '>=2.0.0'
    check-module -name PSReadLine -version '<=2.3.4'
    check-module -name PSReadLine -version '<2.3.4'
    check-module -name PSReadLine -version '>2.3.4'

.OUTPUTS
    The satisfying version of the module [string], or $null when none could be
    resolved or installed.
#>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $name,
        [Parameter(Mandatory = $false)]
        [ValidatePattern('(^(==|>=|<=|>|<)([0-9]+\.[0-9]+\.[0-9]+)$)|(^(latest)$)')]
        [string] $version = "latest"
    )

    # [version] objects, not strings: string ordering puts 2.10.0 below 2.3.4.
    $installed_versions = @(
        Get-Module -ListAvailable -Name $name |
        Sort-Object -Property Version -Descending |
        ForEach-Object { $_.Version })

    # Install $name and return the version that was installed, or $null on failure.
    function Install-Resolved([hashtable] $find_args) {
        try {
            Write-Warning "No installed version of $name satisfies '$version'. Installing..."
            $new_version = (Find-Module -Name $name @find_args).Version
            if ($null -eq $new_version) {
                throw "Unable to find a version of $name matching '$version'"
            }
            sudo Install-Module -Name $name -RequiredVersion $new_version -Force
            return $new_version.ToString()
        } catch {
            Write-Host "Failed to install $name module: $_" -ForegroundColor Red
            return $null
        }
    }

    if ($version -eq "latest") {
        if ($installed_versions.Count -gt 0) {
            return $installed_versions[0].ToString()
        }
        return Install-Resolved @{}
    }

    $version_raw = [version]($version -replace '[=<>]', '')
    $accepts_equal = $version.Contains('=')

    if ($version.StartsWith('>')) {
        foreach ($v in $installed_versions) {
            if (($v -gt $version_raw) -or ($accepts_equal -and $v -eq $version_raw)) {
                return $v.ToString()
            }
        }
        return Install-Resolved @{ MinimumVersion = $version_raw.ToString() }
    }

    if ($version.StartsWith('<')) {
        foreach ($v in $installed_versions) {
            if (($v -lt $version_raw) -or ($accepts_equal -and $v -eq $version_raw)) {
                return $v.ToString()
            }
        }
        return Install-Resolved @{ MaximumVersion = $version_raw.ToString() }
    }

    if ($installed_versions -contains $version_raw) {
        return $version_raw.ToString()
    }
    return Install-Resolved @{ RequiredVersion = $version_raw.ToString() }
}


function global:check-imported {
<#
.SYNOPSIS
    Check if module is imported into the current session
.PARAMETER name
    Name of the module
.PARAMETER imported_list
    List of modules already known to be imported
.EXAMPLE
    check-imported -name Terminal-Icons
.EXAMPLE
    check-imported -name Terminal-Icons -imported_list $global:imported_list
#>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $name,

        [Parameter(Mandatory = $false)]
        [array] $imported_list
    )

    if (-not $imported_list) {
        $imported_list = (Get-Module -Name $name).Name
    }

    if ($imported_list -notcontains $name) {
        Write-Host "module" -ForegroundColor Red -NoNewline
        Write-Host " $name " -ForegroundColor Yellow -NoNewline
        Write-Host "is not imported" -ForegroundColor Red
        return $false
    }

    return $true
}


function global:get-module-import-args {
<#
.SYNOPSIS
    Translate a version constraint ('latest', '==x.y.z', '>=x.y.z', ...) into the
    matching Import-Module parameters.
#>
    param (
        [Parameter(Mandatory = $true)]
        [string] $version
    )

    if ($version -eq "latest") { return @{} }

    $version_raw = ($version -replace '[=<>]', '')

    if ($version.StartsWith('>')) { return @{ MinimumVersion = $version_raw } }
    if ($version.StartsWith('<')) { return @{ MaximumVersion = $version_raw } }
    return @{ RequiredVersion = $version_raw }
}


function global:init-modules {
<#
.SYNOPSIS
    Import, Check, Init and Show Modules
#>

    # $MODULES is what EasyPwsh depends on; $MODULES_OPTIONAL is opt-in.
    $modules_to_load = @{}
    $global:MODULES.GetEnumerator() | ForEach-Object { $modules_to_load[$_.Key] = $_.Value }
    if ($global:MODULE_OPTIONAL_FLAG -and $global:MODULES_OPTIONAL) {
        $global:MODULES_OPTIONAL.GetEnumerator() | ForEach-Object { $modules_to_load[$_.Key] = $_.Value }
    }

    $modules_to_load.GetEnumerator() | ForEach-Object {
        $module_name = $_.Key
        $constraint  = $_.Value

        $import_args = get-module-import-args -Version $constraint

        if ($global:CHECK_MODULES) {
            $resolved = check-module -Name $module_name -Version $constraint
            if (-not $resolved) { return }   # `return` inside ForEach-Object == `continue`
            $import_args = @{ RequiredVersion = $resolved }
        }

        try {
            Import-Module -Name $module_name @import_args -ErrorAction Stop
        } catch {
            Write-Warning "Failed to import module $module_name`: $($_.Exception.Message)"
            return
        }

        $init_module_file = Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "modules\module.$module_name.ps1"
        if (Test-Path $init_module_file) {
            & $init_module_file
        }

        if ($global:SHOW_MODULES) {
            Write-Host "module" -ForegroundColor Green -NoNewline
            Write-Host " $module_name " -ForegroundColor Yellow -NoNewline
            Write-Host "is imported" -ForegroundColor Green
        }
    }
}


function global:init-module { param (
    [Parameter(Mandatory = $true)]
    [string] $name,
    [Parameter(Mandatory = $false)]
    [string] $version = "latest"
)
    $import_args = get-module-import-args -Version $version

    try {
        Import-Module -Name $name @import_args -Force -ErrorAction Stop
    } catch {
        Write-Warning "Failed to import module $name`: $($_.Exception.Message)"
        return
    }

    $init_module_file = Join-Path -Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "modules\module.$($name).ps1"

    if (Test-Path $init_module_file) {
        & $init_module_file
    } else {
        Write-Host "init-module: $init_module_file not found" -ForegroundColor Red
    }
}


if ($global:IMPORT_MODULES) { init-modules }


# TIPS: If you do not want to download modules by yourself, you can try to import the modules in the $global:CURRENT_SCRIPT_DIRECTORY/downloads/Modules
