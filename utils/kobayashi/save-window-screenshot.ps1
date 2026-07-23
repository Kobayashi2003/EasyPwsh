<#
.SYNOPSIS
    Captures a screenshot of a window, the full screen, or a region
.DESCRIPTION
    This PowerShell script saves a PNG screenshot to disk. It can capture the entire
    screen, the foreground window, a window matched by its title, or an explicit
    rectangle. Matching a window title brings that window to the front first, which
    makes the script suitable for documenting applications unattended.
.PARAMETER Path
    Destination PNG file. Parent directories are created when missing.
.PARAMETER WindowTitle
    Substring of the target window title. The first visible match is activated and captured.
.PARAMETER Foreground
    Capture the window that currently has focus.
.PARAMETER Region
    Explicit rectangle to capture as "X,Y,Width,Height".
.PARAMETER DelaySeconds
    Seconds to wait before capturing, giving the window time to repaint.
.EXAMPLE
    PS> ./save-window-screenshot.ps1 -Path shot.png
    ✔️ Saved 1920x1080 screenshot to shot.png
.EXAMPLE
    PS> ./save-window-screenshot.ps1 -Path chrome.png -WindowTitle "Chrome" -DelaySeconds 2
.EXAMPLE
    PS> ./save-window-screenshot.ps1 -Path region.png -Region "0,0,1280,720"
.NOTES
    Author: KOBAYASHI
#>

[CmdletBinding(DefaultParameterSetName = 'Screen')]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(ParameterSetName = 'Window')][string]$WindowTitle,
    [Parameter(ParameterSetName = 'Foreground')][switch]$Foreground,
    [Parameter(ParameterSetName = 'Region')][string]$Region,
    [double]$DelaySeconds = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing, System.Windows.Forms

if (-not ('Win32.ScreenCapture' -as [type])) {
    Add-Type -Namespace Win32 -Name ScreenCapture -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left, Top, Right, Bottom; }

[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

[DllImport("dwmapi.dll")]
public static extern int DwmGetWindowAttribute(IntPtr hWnd, int attr, out RECT value, int size);

// Prefers the DWM extended frame bounds so the drop shadow is not included.
public static RECT GetBounds(IntPtr hWnd) {
    RECT r;
    if (DwmGetWindowAttribute(hWnd, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) {
        GetWindowRect(hWnd, out r);
    }
    return r;
}
'@
}

function Resolve-TargetRect {
    switch ($PSCmdlet.ParameterSetName) {
        'Region' {
            $v = $Region -split '\s*,\s*'
            if ($v.Count -ne 4) { throw "Region must be 'X,Y,Width,Height'" }
            return [System.Drawing.Rectangle]::new([int]$v[0], [int]$v[1], [int]$v[2], [int]$v[3])
        }
        'Window' {
            $proc = Get-Process |
                Where-Object { $_.MainWindowTitle -like "*$WindowTitle*" -and $_.MainWindowHandle -ne 0 } |
                Select-Object -First 1
            if (-not $proc) { throw "No visible window matching '$WindowTitle'" }
            # Windows can refuse the first activation when another app owns the
            # foreground, so retry briefly before giving up.
            for ($i = 0; $i -lt 5; $i++) {
                [void][Win32.ScreenCapture]::ShowWindow($proc.MainWindowHandle, 9)  # SW_RESTORE
                [void][Win32.ScreenCapture]::SetForegroundWindow($proc.MainWindowHandle)
                Start-Sleep -Milliseconds 400
                if ([Win32.ScreenCapture]::GetForegroundWindow() -eq $proc.MainWindowHandle) { break }
            }
            # A locked or occluded desktop would otherwise be captured instead of the window.
            if ([Win32.ScreenCapture]::GetForegroundWindow() -ne $proc.MainWindowHandle) {
                throw "'$WindowTitle' could not be brought to the front (screen locked or window occluded)"
            }
            return Convert-HandleToRect $proc.MainWindowHandle
        }
        'Foreground' {
            return Convert-HandleToRect ([Win32.ScreenCapture]::GetForegroundWindow())
        }
        default {
            return [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        }
    }
}

function Convert-HandleToRect([IntPtr]$handle) {
    $r = [Win32.ScreenCapture]::GetBounds($handle)
    [System.Drawing.Rectangle]::new($r.Left, $r.Top, $r.Right - $r.Left, $r.Bottom - $r.Top)
}

try {
    $rect = Resolve-TargetRect
    if ($rect.Width -le 0 -or $rect.Height -le 0) { throw "Target has an empty area" }

    if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $bitmap = [System.Drawing.Bitmap]::new($rect.Width, $rect.Height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.CopyFromScreen($rect.Location, [System.Drawing.Point]::Empty, $rect.Size)
        } finally { $graphics.Dispose() }

        $full = if ([System.IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path (Get-Location) $Path }
        $bitmap.Save($full, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }

    Write-Host "✔️ Saved $($rect.Width)x$($rect.Height) screenshot to $Path" -ForegroundColor Green
    exit 0 # success
} catch {
    Write-Host "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])" -ForegroundColor Red
    exit 1
}
