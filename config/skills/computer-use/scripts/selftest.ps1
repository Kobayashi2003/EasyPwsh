#Requires -Version 5.1
<#
.SYNOPSIS
    Smoke + regression net for computer.ps1. Drives a scratch Notepad window it owns.

.DESCRIPTION
    Every failure this skill has ever had was SILENT: ctrl+a degrading to a literal 'a',
    edit -Mode copy returning a stale clipboard, ui-tree printing a table and then throwing,
    SendInput returning 0 under UIPI with the result discarded. A smoke test is the only thing
    that turns "it broke three commits ago" into "it broke in this commit".

    Tests already known to be broken live in $KnownFail with the reason. Output separates:
        PASS              - working
        FAIL(expected)    - a known bug, still broken; this is the regression baseline
        FAIL(NEW!)        - THIS change broke something. Exit code 1.
        PASS(unexpected)  - fixed! remove it from $KnownFail so it is guarded from now on.

    Safety: launches its OWN Notepad and only ever targets that process. A Notepad you already
    had open is never touched. IME conversion mode and the text clipboard are saved and restored
    even when a test throws.

.PARAMETER Only
    Run only tests whose name contains this substring (e.g. -Only keys).

.PARAMETER Baseline
    Also measure this machine's cold-start cost. Every timing in the design notes was measured on
    a different machine, so they are not evidence here.

.PARAMETER Force
    Skip the "this drives the real desktop" banner.

.EXAMPLE
    .\selftest.ps1
    .\selftest.ps1 -Only keys -Baseline
#>
[CmdletBinding()]
param(
    [string]$Only,
    [switch]$Baseline,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$CU = Join-Path $PSScriptRoot 'computer.ps1'
if (-not (Test-Path $CU)) { throw "computer.ps1 not found next to this script ($CU)" }

# ══ Known-broken baseline ═══════════════════════════════════════════════════════════════════
# Name -> why. Shrink this list as fixes land; never add to it to make a run green.
$KnownFail = @{
    # Empty as of 2026-08-08: the six bugs this list was created to pin down are all fixed
    # (case-collision on $MODS, WM_COPY stale clipboard, Walk-Uia depth, @(List) throwing,
    # window-move coordinate space). Anything that fails now is a regression.
}

# ══ Harness ═════════════════════════════════════════════════════════════════════════════════
$Results = [System.Collections.Generic.List[object]]::new()

function Assert([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

# Invoke computer.ps1. Captures stdout+stderr and the real exit code so a test can assert that a
# command FAILED — half these bugs are commands that succeed when they should not.
function Cu {
    $global:LASTEXITCODE = 0
    $script:LastOut  = (& $CU @args 2>&1 | Out-String)
    $script:LastExit = $LASTEXITCODE
    $script:LastOut
}

function Test-Case([string]$Name, [scriptblock]$Body) {
    if ($Only -and $Name -notlike "*$Only*") { return }
    $expected = $KnownFail.ContainsKey($Name)
    $detail = ''
    try { & $Body; $ok = $true } catch { $ok = $false; $detail = $_.Exception.Message }

    $status = if ($ok -and -not $expected) { 'PASS' }
              elseif ($ok -and $expected)  { 'PASS(unexpected)' }
              elseif ($expected)           { 'FAIL(expected)' }
              else                         { 'FAIL(NEW!)' }

    $colour = switch ($status) {
        'PASS'             { 'Green' }
        'FAIL(expected)'   { 'DarkYellow' }
        'PASS(unexpected)' { 'Cyan' }
        default            { 'Red' }
    }
    $note = if ($status -eq 'PASS(unexpected)') { "fixed - remove from `$KnownFail" } else { $detail }
    Write-Host ('{0,-17} {1,-28} {2}' -f $status, $Name, $note) -ForegroundColor $colour
    $Results.Add([pscustomobject]@{ Name = $Name; Status = $status })
}

# ── helpers over computer.ps1's text output ──────────────────────────────────────────────────
function Get-EditText {
    # "edit read 'Edit' (N chars):" + body
    $raw = Cu -Action edit -Mode read
    ($raw -split "`r?`n", 2)[1].TrimEnd("`r", "`n")
}
function Set-EditText([string]$Text) {
    $null = Cu -Action focus -Hwnd $Hwnd
    $null = Cu -Action edit -Mode clear
    $null = Cu -Action type -Text $Text -Mode msg
}
function Get-ImeConv {
    if ((Cu -Action ime -Mode report) -match 'conv=0x([0-9A-Fa-f]+)') { $Matches[1] } else { $null }
}

# ══ Environment guard + scratch window ══════════════════════════════════════════════════════
if (-not $Force) {
    Write-Host "selftest drives the REAL desktop: it takes focus, types into a scratch Notepad," -ForegroundColor Yellow
    Write-Host "and toggles the IME. Don't type elsewhere while it runs. (-Force to silence.)`n" -ForegroundColor Yellow
}

$Proc = Start-Process notepad -PassThru
$null = $Proc.WaitForInputIdle(5000)
Start-Sleep -Milliseconds 500
$Proc.Refresh()
$Hwnd = [int64]$Proc.MainWindowHandle
if ($Hwnd -eq 0) { $Proc | Stop-Process -Force; throw "scratch Notepad never produced a window" }

$OrigConv = Get-ImeConv
$OrigClip = try { Get-Clipboard -Raw -ErrorAction Stop } catch { $null }
Write-Host "scratch Notepad hwnd=$Hwnd  pid=$($Proc.Id)  ime conv=0x$OrigConv`n"

try {
    # ══ Self-containment ════════════════════════════════════════════════════════════════════
    # The script lives in a dotfiles repo but must run identically outside it.
    Test-Case 'env/self-contained' {
        $src = Get-Content $CU -Raw
        Assert ($src -notmatch 'EasyPwsh') 'computer.ps1 still references EasyPwsh'
        Assert ($src -notmatch '\$global:') 'computer.ps1 reads a global set by some shell profile'
    }

    # Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so every box-drawing character and
    # CJK string turns to mush - which broke selftest.ps1's own brace matching, not just its
    # output. Both files carry non-ASCII, so both need the BOM. Editors and codegen strip it
    # silently, hence the guard.
    Test-Case 'env/utf8-bom' {
        foreach ($f in @($CU, $PSCommandPath)) {
            $b = [IO.File]::ReadAllBytes($f)[0..2]
            Assert ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) "$(Split-Path $f -Leaf) lost its UTF-8 BOM; Windows PowerShell 5.1 will misparse it"
        }
    }

    # The compiled P/Invoke block is cached as a DLL keyed by computer.ps1's mtime. If that key
    # ever stopped tracking the source, the failure mode is the worst kind this skill has: an old
    # DLL loaded against new script code, silently.
    Test-Case 'env/dll-cache-tracks-source' {
        $null = Cu -Action screen-size
        $key = 'CU-{0:x}-ps{1}.dll' -f (Get-Item $CU).LastWriteTimeUtc.Ticks, $PSVersionTable.PSVersion.Major
        $dir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'computer-use-skill'
        Assert (Test-Path (Join-Path $dir $key)) "no cache entry '$key' after a run - the cache key no longer follows the source mtime"
    }

    Test-Case 'env/windows-powershell-5.1' {
        $out = powershell.exe -NoProfile -Command "& '$CU' -Action screen-size" 2>&1 | Out-String
        Assert ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE under Windows PowerShell 5.1"
        Assert ($out -match 'virtual-desktop') "unexpected 5.1 output: $out"
    }

    # ══ Query / probe ═══════════════════════════════════════════════════════════════════════
    Test-Case 'query/screen-size' {
        Assert ((Cu -Action screen-size) -match 'virtual-desktop:\s*-?\d+,-?\d+,\d+,\d+') "no virtual-desktop line: $LastOut"
    }

    Test-Case 'query/pixel' {
        Assert ((Cu -Action pixel -X 100 -Y 100) -match '#[0-9A-F]{6}') "no colour: $LastOut"
    }

    Test-Case 'window/find-window-sees-scratch' {
        $out = Cu -Action find-window -Filter notepad
        Assert ($out -match [regex]::Escape("$Hwnd")) "find-window did not list hwnd $Hwnd`n$out"
    }

    # ══ Text I/O (no keyboard involved) ═════════════════════════════════════════════════════
    Test-Case 'text/type-msg-roundtrip' {
        Set-EditText 'selftest-ascii'
        Assert ((Get-EditText) -eq 'selftest-ascii') "read back '$(Get-EditText)'"
    }

    Test-Case 'text/type-cjk-and-emoji' {
        # type must not route CJK through the keyboard, where an IME would eat it.
        Set-EditText '中文 CJK 🎯'
        Assert ((Get-EditText) -eq '中文 CJK 🎯') "read back '$(Get-EditText)'"
    }

    Test-Case 'text/edit-clear' {
        Set-EditText 'to-be-cleared'
        $null = Cu -Action edit -Mode clear
        Assert ((Get-EditText) -eq '') "clear left '$(Get-EditText)'"
    }

    # A verification API that lies is worse than an action API that breaks: it makes the failure
    # silent. With no selection WM_COPY is a no-op, so whatever was on the clipboard comes back
    # looking like a fresh read.
    Test-Case 'edit/copy-no-selection' {
        Set-Clipboard -Value 'STALE-SENTINEL'
        Set-EditText 'different-text'
        $out = Cu -Action edit -Mode copy
        Assert ($LastExit -ne 0) "copy with no selection succeeded and returned: $out"
    }

    # ══ Keyboard ════════════════════════════════════════════════════════════════════════════
    # THE test. 'ctrl+a delete' must empty the control. If the modifier is dropped, a literal 'a'
    # is inserted instead and the text survives. Run in BOTH IME modes: the whole point of the
    # finding is that this is not an IME-mode problem, so a fix must hold in both.
    function Test-ComboAtomic {
        Set-EditText 'SELFTEST-COMBO'
        $null = Cu -Action keys -Keys 'ctrl+a delete'
        $after = Get-EditText
        Assert ($after -eq '') "ctrl+a delete left '$after' - the modifier was dropped"
    }

    Test-Case 'keys/combo-atomic-en' {
        $null = Cu -Action ime -Mode english
        Test-ComboAtomic
    }

    Test-Case 'keys/combo-atomic-cn' {
        $null = Cu -Action ime -Mode native
        try { Test-ComboAtomic } finally {
            $null = Cu -Action ime -Mode english   # drop any pending composition before moving on
            $null = Cu -Action edit -Mode clear
        }
    }

    Test-Case 'keys/non-alpha-passthrough' {
        # enter/tab never touch the IME; they must work regardless of the combo bug.
        Set-EditText 'line1'
        $null = Cu -Action keys -Keys 'enter'
        $null = Cu -Action type -Text 'line2' -Mode msg
        Assert ((Get-EditText) -match 'line1[\r\n]+line2') "got '$(Get-EditText)'"
    }

    # ══ UI Automation ═══════════════════════════════════════════════════════════════════════
    Test-Case 'uia/ui-find-returns-rows' {
        $out = Cu -Action ui-find -Hwnd $Hwnd
        Assert ($LastExit -eq 0) "ui-find exit $LastExit"
        Assert ($out -match 'Click\s*=') "no rows from ui-find:`n$out"
    }

    # Notepad's panes are children of its window, so at least one row must report Depth >= 1.
    # A tree that is entirely depth 0 is not a flat tree - it is a broken counter.
    Test-Case 'uia/depth-is-nested' {
        $depths = @([regex]::Matches((Cu -Action ui-find -Hwnd $Hwnd), '(?m)^\s*(\d+)\s+\S') |
                    ForEach-Object { [int]$_.Groups[1].Value })
        Assert ($depths.Count -gt 1) 'not enough rows to judge nesting'
        Assert (($depths | Where-Object { $_ -gt 0 }).Count -gt 0) "every row reports Depth 0 ($($depths.Count) rows)"
    }

    Test-Case 'uia/ui-tree-succeeds' {
        $out = Cu -Action ui-tree -Hwnd $Hwnd -Depth 4
        Assert ($LastExit -eq 0) "ui-tree exit $LastExit :`n$out"
    }

    # ══ Mouse / window / capture ════════════════════════════════════════════════════════════
    # click -Modifiers takes a different path from `keys` (Push-Modifiers, held around the mouse
    # event), so the modifier bug that hit Send-Combo could plausibly have hit here too. It did
    # not - but only a measurement says so. shift+click extends the selection, and edit -Mode copy
    # now refuses when there is no selection, so a successful copy IS the assertion.
    Test-Case 'mouse/shift-click-extends-selection' {
        $null = Cu -Action window-move -Hwnd $Hwnd -X 200 -Y 150 -W 700 -H 500
        Set-EditText ('ABCDEFGHIJ' * 12)
        $null = Cu -Action click -X 260 -Y 240
        $null = Cu -Action click -X 520 -Y 240 -Modifiers shift
        $out = Cu -Action edit -Mode copy
        Assert ($LastExit -eq 0) "shift+click produced no selection, so the modifier was dropped:`n$out"
    }

    Test-Case 'mouse/move-roundtrip' {
        $null = Cu -Action move -X 700 -Y 400
        Assert ((Cu -Action mouse-pos) -match 'mouse:\s*700,400') "mouse-pos says: $LastOut"
    }

    # window-move must speak the same coordinates as everything else in this skill: the DWM
    # visible frame that find-window, ui-find and screenshot -Region all report.
    Test-Case 'window/window-move' {
        $null = Cu -Action window-move -Hwnd $Hwnd -X 200 -Y 150 -W 700 -H 500
        $out = Cu -Action find-window -Filter notepad
        Assert ($out -match '200,150,700,500') "asked for 200,150,700,500; find-window reports:`n$out"
    }

    Test-Case 'screenshot/region-crop' {
        $png = Join-Path ([IO.Path]::GetTempPath()) 'cu-selftest.png'
        Remove-Item $png -ErrorAction SilentlyContinue
        $null = Cu -Action screenshot -Region '200,150,400,300' -Path $png
        Assert (Test-Path $png) 'no PNG written'
        Add-Type -AssemblyName System.Drawing
        $img = [System.Drawing.Image]::FromFile($png)
        try { Assert ($img.Width -eq 400 -and $img.Height -eq 300) "got $($img.Width)x$($img.Height), wanted 400x300" }
        finally { $img.Dispose(); Remove-Item $png -ErrorAction SilentlyContinue }
    }

    Test-Case 'batch/multi-step-one-process' {
        $out = Cu -Action batch -Batch "focus hwnd=$Hwnd`nedit mode=clear`ntype text=`"batched`" mode=msg`nedit mode=read"
        Assert ($LastExit -eq 0) "batch exit $LastExit :`n$out"
        Assert ($out -match 'batched') "batch did not reach the last step:`n$out"
    }

    # ══ Baseline (this machine, today) ══════════════════════════════════════════════════════
    if ($Baseline) {
        Write-Host "`n── baseline: $env:COMPUTERNAME, $((Get-CimInstance Win32_OperatingSystem).Caption) build $((Get-CimInstance Win32_OperatingSystem).BuildNumber), PS $($PSVersionTable.PSVersion) ──" -ForegroundColor Cyan
        # Must spawn a REAL process. Calling & $CU in-process reuses this session's already-JITted
        # types and reports ~10ms, which is a plausible-looking number that measures nothing.
        $exe = (Get-Process -Id $PID).Path
        function Measure-Run([string[]]$ScriptArgs, [int]$Reps = 3) {
            (1..$Reps | ForEach-Object {
                (Measure-Command { & $exe -NoProfile -File $CU @ScriptArgs | Out-Null }).TotalMilliseconds
            } | Measure-Object -Average).Average
        }
        $cold = Measure-Run @('-Action', 'screen-size')
        $five = Measure-Run @('-Action', 'batch', '-Batch', "screen-size`nmouse-pos`nscreen-size`nmouse-pos`nscreen-size")
        Write-Host ("cold process, 1 action  : {0,7:N0} ms" -f $cold)
        Write-Host ("cold process, 5 actions : {0,7:N0} ms" -f $five)
        Write-Host ("=> 4 extra actions cost   {0,7:N0} ms total ({1:N0} ms each)" -f ($five - $cold), (($five - $cold) / 4))
        Write-Host ("=> 5 separate processes would cost {0:N0} ms, so batching saves ~{1:N0} ms" -f ($cold * 5), ($cold * 5 - $five))
        Write-Host "   (what batch saves is process startup + agent round-trips, NOT repeated P/Invoke compilation)"
    }
}
finally {
    if ($OrigConv) { $null = Cu -Action ime -Mode "0x$OrigConv" }
    if ($null -ne $OrigClip) { Set-Clipboard -Value $OrigClip } else { Set-Clipboard -Value '' }
    Get-Process -Id $Proc.Id -ErrorAction SilentlyContinue | Stop-Process -Force
}

# ══ Verdict ═════════════════════════════════════════════════════════════════════════════════
$new    = @($Results | Where-Object Status -eq 'FAIL(NEW!)')
$fixed  = @($Results | Where-Object Status -eq 'PASS(unexpected)')
$known  = @($Results | Where-Object Status -eq 'FAIL(expected)')
$passed = @($Results | Where-Object Status -eq 'PASS')

Write-Host ("`n{0} passed, {1} known-broken, {2} newly broken, {3} newly fixed" -f
    $passed.Count, $known.Count, $new.Count, $fixed.Count)

if ($fixed.Count) {
    Write-Host "remove from `$KnownFail: $($fixed.Name -join ', ')" -ForegroundColor Cyan
}
if ($new.Count) {
    Write-Host "REGRESSION: $($new.Name -join ', ')" -ForegroundColor Red
    exit 1
}
exit 0
