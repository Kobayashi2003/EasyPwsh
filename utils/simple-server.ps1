<#
.SYNOPSIS
    Serves an HTML file or directory using a simple HTTP server.
.PARAMETER file
    The HTML file to serve directly.
.PARAMETER directory
    The directory to serve files from.
.PARAMETER port
    The port number to use (default: 8000).
.PARAMETER bind
    The address to bind to (default: 127.0.0.1).

.EXAMPLE
    PS> ./simple-server.ps1 -file "path/to/your/file.html"
.EXAMPLE
    PS> ./simple-server.ps1 -directory "path/to/your/directory" -port 9000
#>

param(
    [Parameter(Mandatory=$false, ParameterSetName="File", HelpMessage="The HTML file to serve directly.")]
    [alias("f")]
    [string] $file,

    [Parameter(Mandatory=$false, ParameterSetName="Directory", HelpMessage="The directory to serve files from.")]
    [alias("d")]
    [string] $directory,

    [Parameter(Mandatory=$false, HelpMessage="The port number to use (default: 8000).")]
    [alias("p")]
    [int] $port = 8000,

    [Parameter(Mandatory=$false, HelpMessage="The address to bind to (default: 127.0.0.1).")]
    [alias("b")]
    [string] $bind = "127.0.0.1"
)

$cur_dir = Get-Location
$script_path = Split-Path $MyInvocation.MyCommand.Path
$python_script_folder = Join-Path -Path $script_path -ChildPath "python-common"

if (-not (Test-Path -Path $python_script_folder)) {
    Write-Host "Please put python-common in the same directory with this script" -ForegroundColor Red
    exit 1
}

Set-Location $python_script_folder

$argArray = @()

if ($file) {
    $file_path = Resolve-Path -Path $file -ErrorAction SilentlyContinue
    if (-not $file_path) {
        $file_path = Join-Path -Path $cur_dir -ChildPath $file
    }
    $argArray += "--file"
    $argArray += "$file_path"
}
elseif ($directory) {
    $dir_path = Resolve-Path -Path $directory -ErrorAction SilentlyContinue
    if (-not $dir_path) {
        $dir_path = Join-Path -Path $cur_dir -ChildPath $directory
    }
    $argArray += "--directory"
    $argArray += "$dir_path"
}

$argArray += "--port"
$argArray += "$port"
$argArray += "--bind"
$argArray += "$bind"

Write-Host "Running: python ./simple_server.py $($argArray -join ' ')"

& pixi run python ./simple_server.py @argArray

Set-Location $cur_dir
