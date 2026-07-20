<#
.SYNOPSIS
    Relocates the current user's Windows shell folders (Desktop, Documents, Searches, ...) to another root
.DESCRIPTION
    This PowerShell script moves the well-known user folders of the *current* user
    to a new root directory. It never touches other users or machine-wide settings.

    For every folder it:
      1. resolves the folder's current location through the Known Folder API
         (never a hard-coded C:\Users\... path),
      2. registers the new location with SHSetKnownFolderPath, which updates both
         the modern Known Folder registration and the legacy
         "User Shell Folders" registry values,
      3. moves the existing content over with robocopy /MOVE.

    Before anything is touched a change map is printed: folders that actually move
    are highlighted, folders that stay where they are (already at the destination,
    excluded, or missing) are dimmed.

    Paths are displayed tokenized (%USERPROFILE%\Desktop) so the map stays readable
    and machine independent.
.PARAMETER Destination
    The new root directory that will hold the relocated folders, e.g. D:\UserProfile.
    Each folder keeps its own leaf name below that root.
.PARAMETER Exclude
    One or more folder names to leave untouched. By default *all* known folders move.
.PARAMETER DryRun
    Only print the change map, then exit without moving anything.
.PARAMETER Force
    Skip the interactive confirmation prompt.
.PARAMETER SkipRestartExplorer
    Do not offer to restart Explorer at the end. Explorer keeps showing the old
    locations until it is restarted or the user signs out again.
.EXAMPLE
    PS> ./move-user-folders.ps1 D:\UserProfile
.EXAMPLE
    PS> ./move-user-folders.ps1 -Destination D:\UserProfile -Exclude Desktop, Downloads
.EXAMPLE
    PS> ./move-user-folders.ps1 D:\UserProfile -DryRun
.NOTES
    Author: KOBAYASHI
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Destination,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Desktop', 'Documents', 'Downloads', 'Music', 'Pictures', 'Videos',
                 'Favorites', 'Links', 'Contacts', 'Searches', 'SavedGames', 'Objects3D')]
    [string[]]$Exclude = @(),

    [switch]$DryRun,

    [switch]$Force,

    [switch]$SkipRestartExplorer
)

# Name -> KNOWNFOLDERID. The GUIDs are the stable identity of each folder; the
# display name below them is localized and the path is user-configurable, so the
# GUID is the only thing safe to hard-code here.
$KnownFolders = [ordered]@{
    Desktop    = 'B4BFCC3A-DB2C-424C-B029-7FE99A87C641'
    Documents  = 'FDD39AD0-238F-46AF-ADB4-6C85480369C7'
    Downloads  = '374DE290-123F-4565-9164-39C4925E467B'
    Music      = '4BD8D571-6D19-48D3-BE97-422220080E43'
    Pictures   = '33E28130-4E1E-4676-835A-98395C3BC3BB'
    Videos     = '18989B1D-99B5-455B-841C-AB7C74E4DDFC'
    Favorites  = '1777F761-68AD-4D8A-87BD-30B759FA33DD'
    Links      = 'BFB9D5E0-C6A9-404C-B2B2-AE6DB6AF4968'
    Contacts   = '56784854-C6CB-462B-8169-88E350ACB882'
    Searches   = '7D1D3A04-DEBB-4115-95CF-2F29DA2920DA'
    SavedGames = '4C5C32FF-BB9D-43B0-B5B4-2D72E54EAAA4'
    Objects3D  = '31C0DD25-9439-4F12-BF41-7FF4EDA38722'
}

if (-not ('EasyPwsh.KnownFolder' -as [type])) {
    Add-Type -Namespace 'EasyPwsh' -Name 'KnownFolder' -MemberDefinition @'
[DllImport("shell32.dll")]
public static extern int SHGetKnownFolderPath(ref Guid rfid, uint dwFlags, IntPtr hToken, out IntPtr ppszPath);

[DllImport("shell32.dll")]
public static extern int SHSetKnownFolderPath(ref Guid rfid, uint dwFlags, IntPtr hToken, [MarshalAs(UnmanagedType.LPWStr)] string pszPath);

[DllImport("shell32.dll")]
public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

// KF_FLAG_DONT_VERIFY (0x4000) so a folder whose backing directory is missing
// still reports its registered path instead of failing.
public static string GetPath(string guid) {
    Guid id = new Guid(guid);
    IntPtr buffer = IntPtr.Zero;
    int hr = SHGetKnownFolderPath(ref id, 0x00004000, IntPtr.Zero, out buffer);
    if (hr != 0) { throw new System.ComponentModel.Win32Exception(hr); }
    try { return Marshal.PtrToStringUni(buffer); }
    finally { Marshal.FreeCoTaskMem(buffer); }
}

public static void SetPath(string guid, string path) {
    Guid id = new Guid(guid);
    int hr = SHSetKnownFolderPath(ref id, 0, IntPtr.Zero, path);
    if (hr != 0) { throw new System.ComponentModel.Win32Exception(hr); }
}

public static void RefreshShell() {
    SHChangeNotify(0x08000000 /* SHCNE_ASSOCCHANGED */, 0 /* SHCNF_IDLIST */, IntPtr.Zero, IntPtr.Zero);
}
'@
}

# Replace the well-known prefixes back with their environment variable so the map
# reads the same on any machine.
function Format-TokenizedPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return '(not set)' }
    foreach ($token in @('USERPROFILE', 'OneDrive', 'LOCALAPPDATA', 'APPDATA')) {
        $value = [Environment]::GetEnvironmentVariable($token)
        if ($value -and $path.StartsWith($value, [StringComparison]::OrdinalIgnoreCase)) {
            return "%$token%" + $path.Substring($value.Length)
        }
    }
    return $path
}

function Test-IsSubPath([string]$child, [string]$parent) {
    $c = [IO.Path]::GetFullPath($child).TrimEnd('\') + '\'
    $p = [IO.Path]::GetFullPath($parent).TrimEnd('\') + '\'
    return $c.StartsWith($p, [StringComparison]::OrdinalIgnoreCase)
}

try {
    # --- resolve the destination root ------------------------------------------------
    $destinationRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Destination))

    # --- build the plan --------------------------------------------------------------
    $plan = foreach ($name in $KnownFolders.Keys) {
        $guid = $KnownFolders[$name]
        $current = $null
        $reason = $null

        try {
            $current = [EasyPwsh.KnownFolder]::GetPath($guid)
        } catch {
            $reason = 'unavailable on this system'
        }

        $target = if ($current) { Join-Path $destinationRoot (Split-Path $current -Leaf) } else { $null }

        if (-not $reason) {
            if ($name -in $Exclude) {
                $reason = 'excluded'
            } elseif ($current -and $target -and ($current.TrimEnd('\') -ieq $target.TrimEnd('\'))) {
                $reason = 'already there'
            } elseif ($current -and -not (Test-Path -LiteralPath $current)) {
                $reason = 'source missing'
            } elseif ($current -and (Test-IsSubPath $target $current)) {
                # Moving a folder into itself would recurse forever under robocopy /MOVE.
                $reason = 'target is inside source'
            }
        }

        [PSCustomObject]@{
            Name    = $name
            Guid    = $guid
            Current = $current
            Target  = $target
            Skip    = [bool]$reason
            Reason  = $reason
        }
    }

    # --- print the change map --------------------------------------------------------
    $nameWidth = ($plan.Name | Measure-Object -Maximum -Property Length).Maximum
    $fromWidth = ($plan | ForEach-Object { (Format-TokenizedPath $_.Current).Length } | Measure-Object -Maximum).Maximum

    Write-Host ""
    Write-Host "Destination root: $destinationRoot"
    Write-Host ""

    foreach ($item in $plan) {
        $from = Format-TokenizedPath $item.Current
        $line = "  {0} {1} -> " -f $item.Name.PadRight($nameWidth), $from.PadRight($fromWidth)

        if ($item.Skip) {
            Write-Host ($line + "(unchanged: $($item.Reason))") -ForegroundColor DarkGray
        } else {
            Write-Host $line -NoNewline
            Write-Host $item.Target -ForegroundColor Green
        }
    }

    $moves = @($plan | Where-Object { -not $_.Skip })
    Write-Host ""
    Write-Host "$($moves.Count) of $($plan.Count) folder(s) will be moved."

    if ($DryRun) {
        Write-Host "Dry run — nothing was changed." -ForegroundColor Yellow
        exit 0
    }
    if ($moves.Count -eq 0) {
        Write-Host "Nothing to do." -ForegroundColor Yellow
        exit 0
    }

    # --- confirm ---------------------------------------------------------------------
    if (-not $Force) {
        $answer = Read-Host "Proceed? [y/N]"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host "Aborted." -ForegroundColor Yellow
            exit 0
        }
    }

    # --- move ------------------------------------------------------------------------
    $failed = 0
    foreach ($item in $moves) {
        Write-Host ""
        Write-Host "→ $($item.Name): $(Format-TokenizedPath $item.Current) -> $($item.Target)" -ForegroundColor Cyan

        try {
            if (-not (Test-Path -LiteralPath $item.Target)) {
                New-Item -ItemType Directory -Path $item.Target -Force | Out-Null
            }

            # Register the new location first: if this fails we have not touched any
            # file yet and the folder is still fully intact at its old path.
            [EasyPwsh.KnownFolder]::SetPath($item.Guid, $item.Target)

            # /E   include empty subdirectories        /MOVE   delete the source afterwards
            # /DCOPY:DAT keep directory timestamps     /R:1 /W:1 fail fast on locked files
            $null = robocopy $item.Current $item.Target /E /MOVE /DCOPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
            $code = $LASTEXITCODE

            # robocopy: 0-7 are success//informational, >= 8 means at least one failure.
            if ($code -ge 8) {
                throw "robocopy exited with code $code — content was left in place, but the folder is now registered at the new location."
            }

            Write-Host "  ✔️ done" -ForegroundColor Green
        } catch {
            $failed++
            Write-Host "  ⚠️ $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    [EasyPwsh.KnownFolder]::RefreshShell()

    Write-Host ""
    if ($failed -gt 0) {
        Write-Host "Finished with $failed failure(s)." -ForegroundColor Red
    } else {
        Write-Host "Finished. All $($moves.Count) folder(s) moved." -ForegroundColor Green
    }

    # Explorer caches the old locations in-process until it is restarted.
    if (-not $SkipRestartExplorer) {
        $answer = if ($Force) { 'n' } else { Read-Host "Restart Explorer now to apply the change? [y/N]" }
        if ($answer -match '^(y|yes)$') {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Write-Host "Explorer restarted." -ForegroundColor Green
        } else {
            Write-Host "Restart Explorer (or sign out) to see the new locations." -ForegroundColor Yellow
        }
    }

    exit $(if ($failed -gt 0) { 1 } else { 0 })
} catch {
    Write-Host "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])" -ForegroundColor Red
    exit 1
}
