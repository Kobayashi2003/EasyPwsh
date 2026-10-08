<#
.SYNOPSIS
    Initialize conda
.NOTES
    https://github.com/conda/conda
#>

#region conda initialize
if (-not (Get-Command 'conda' -ErrorAction SilentlyContinue)) {
    return
}

# (& { conda config --set changeps1 False })
# (& { conda config --set auto_activate_base False })

$conda_conf = Join-Path $global:CURRENT_SCRIPT_DIRECTORY -ChildPath "config\conda\.condarc"
$conda_conf_current_user = Join-Path $env:USERPROFILE -ChildPath ".condarc"

New-ManagedSymlink -Path $conda_conf_current_user -Target $conda_conf

# Lazy load: running `conda shell.powershell hook` spawns Python and costs ~1.1s
# every shell. Instead, define a lightweight stub that, on first `conda` call,
# expands the (cached) hook and re-dispatches. Conda's hook imports Conda.psm1,
# which registers the real `conda` command into the global scope, so activation
# keeps working. Most sessions never touch conda and pay zero startup cost.
function global:conda {
    Remove-Item Function:\conda -Force -ErrorAction SilentlyContinue
    $__conda_exe   = (Get-Command conda -CommandType Application | Select-Object -First 1).Source
    $__conda_dir   = Join-Path $global:CURRENT_SCRIPT_DIRECTORY 'downloads\cache'
    $__conda_cache = Join-Path $__conda_dir ('conda-hook-utf8-ps{0}.ps1' -f $PSVersionTable.PSVersion.Major)
    if (-not (Test-Path $__conda_cache) -or
        ((Get-Item $__conda_exe).LastWriteTimeUtc -gt (Get-Item $__conda_cache).LastWriteTimeUtc)) {
        if (-not (Test-Path $__conda_dir)) { New-Item -ItemType Directory -Force -Path $__conda_dir | Out-Null }
        $hook = Invoke-EasyPwshUtf8Command -FilePath $__conda_exe -ArgumentList @('shell.powershell', 'hook') -Environment @{ PYTHONIOENCODING = 'utf-8' }
        [IO.File]::WriteAllText($__conda_cache, $hook, [Text.UTF8Encoding]::new($true))
    }
    . $__conda_cache
    conda @args
}
#endregion
