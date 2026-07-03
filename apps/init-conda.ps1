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

if (!(Test-Path $conda_conf_current_user)) {
    & sudo New-Item -Path $conda_conf_current_user -ItemType SymbolicLink -Value $conda_conf
}

# Lazy load: running `conda shell.powershell hook` spawns Python and costs ~1.1s
# every shell. Instead, define a lightweight stub that, on first `conda` call,
# expands the (cached) hook and re-dispatches. Conda's hook imports Conda.psm1,
# which registers the real `conda` command into the global scope, so activation
# keeps working. Most sessions never touch conda and pay zero startup cost.
function global:conda {
    Remove-Item Function:\conda -Force -ErrorAction SilentlyContinue
    $__conda_exe   = (Get-Command conda -CommandType Application | Select-Object -First 1).Source
    $__conda_dir   = Join-Path $global:CURRENT_SCRIPT_DIRECTORY 'downloads\cache'
    $__conda_cache = Join-Path $__conda_dir 'conda-hook.ps1'
    if (-not (Test-Path $__conda_cache) -or
        ((Get-Item $__conda_exe).LastWriteTimeUtc -gt (Get-Item $__conda_cache).LastWriteTimeUtc)) {
        if (-not (Test-Path $__conda_dir)) { New-Item -ItemType Directory -Force -Path $__conda_dir | Out-Null }
        (& $__conda_exe 'shell.powershell' 'hook' | Out-String) |
            Set-Content -LiteralPath $__conda_cache -Encoding UTF8
    }
    . $__conda_cache
    conda @args
}
#endregion