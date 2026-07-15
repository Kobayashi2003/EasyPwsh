<#
.SYNOPSIS
    Standalone engine for reading mouse clicks as console-cell coordinates.
    Mouse reporting is only active while a capture is in progress, so key
    handling and terminal text selection stay untouched the rest of the time.

    Explored step by step in test\model-mouse-cursor.ps1; the traps are in
    test\test-mouse-cursor.ps1.
#>

function global:Write-ConsoleVT { param([string] $Sequence)
<#
.SYNOPSIS
    Write an escape sequence to the terminal.
.DESCRIPTION
    The flush is insurance, not a fix: [Console]::Out has been observed pushing
    these out on its own. But a mouse-reporting request the terminal has not
    received yet means it sends no clicks at all, which is a miserable thing to
    debug, so do not leave it to chance.
#>
    [Console]::Out.Write($Sequence)
    [Console]::Out.Flush()
}

function global:Read-MouseCell {
<#
.SYNOPSIS
    Stream the screen cell of every mouse press and drag, until a key is pressed.
.DESCRIPTION
    Meant to be bound to a key: press it once to start, click and drag to your
    heart's content, press any key to stop -- a toggle, not a hold. The trap with
    a hold is the trigger key auto-repeating into the capture; a toggle sidesteps
    it by waiting for the trigger to be released before the capture even begins.

    Asks the terminal to report mouse input (SGR: ESC[?1000;1002;1006h), turns the
    escape sequences it sends back into cells, and restores the console mode on
    the way out.

    Cells are written to the pipeline as they arrive, so the caller must consume
    them with a pipeline too:

        Read-MouseCell | ForEach-Object { ... }      # runs per click, live
        foreach ($c in (Read-MouseCell)) { ... }     # runs only once it is over

    `foreach` collects every object before its first iteration, which is exactly
    how this feature failed to track the cursor the first time round.
.PARAMETER TriggerKey
    Virtual-key code of the key that started the capture (default 0x12, Alt). The
    capture waits for it to be released before it begins, so its auto-repeat never
    reaches the loop.
.PARAMETER TimeoutMs
    End the capture after this long with no mouse activity.
.OUTPUTS
    [pscustomobject] per press or drag step, with Column/Row (0-based viewport
    cells) and Button (0 left, 1 middle, 2 right). Nothing at all on a terminal
    that does not report mouse input.
#>
    param(
        [int] $TriggerKey = 0x12,
        [int] $TimeoutMs = 10000
    )

    # conhost delivers mouse input as MOUSE_EVENT records, never VT sequences.
    if (-not ($env:WT_SESSION -or $env:TERM_PROGRAM)) { return }

    $ESC = [char]27

    try {
        $handle  = [WinApi]::GetStdHandle(-10)
        $oldMode = [uint32]0
        if (-not [WinApi]::GetConsoleMode($handle, [ref]$oldMode)) { return }
    } catch { return }

    # VT input + mouse input on, QuickEdit off (it swallows clicks).
    $newMode = ($oldMode -bor 0x200 -bor 0x10 -bor 0x80) -band (-bnot [uint32]0x40)

    try {
        [void][WinApi]::SetConsoleMode($handle, $newMode)
        # 1000 = clicks, 1002 = movement while a button is down (drag), 1006 = SGR.
        Write-ConsoleVT "${ESC}[?1000;1002;1006h"

        # Settle: wait for the trigger key to come back up, then throw away
        # everything it queued while it was down. After this the queue holds only
        # what you do next, so the main loop needs no special-casing for the
        # trigger -- a plain keystroke can only be you starting to type.
        while ([WinApi]::GetAsyncKeyState($TriggerKey) -band 0x8000) {
            Start-Sleep -Milliseconds 5
        }
        Start-Sleep -Milliseconds 20   # let the last repeats land before draining
        while ([ConsoleInput]::PeekChar($handle) -ge 0) { [ConsoleInput]::Consume($handle) }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $seq = ''
        $dragging = $false
        $escAt = -1

        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {

            # System.Console's input layer will not hand a mouse sequence over
            # while it is waiting for a keystroke, so read the queue directly --
            # but only LOOK first. Whatever is not ours has to stay in the queue
            # for PSReadLine, or the first thing typed after a capture is lost.
            $code = [ConsoleInput]::PeekChar($handle)

            if ($code -lt 0) {
                # A lone Esc that nothing follows is the Esc key, not the start of
                # a mouse report. Give the rest of the sequence 50ms to show up.
                if ($seq.Length -eq 1 -and $sw.ElapsedMilliseconds - $escAt -gt 50) { break }
                Start-Sleep -Milliseconds 5
                continue
            }

            $ch = [char]$code

            # Not mid-sequence and not an Esc: a plain keystroke, which belongs to
            # the line editor. Leave it in the queue and stop -- so you end the
            # capture just by typing, and the character still arrives.
            if ($seq.Length -eq 0 -and $ch -ne $ESC) { break }

            [ConsoleInput]::Consume($handle)
            $seq += $ch
            if ($seq.Length -eq 1) { $escAt = $sw.ElapsedMilliseconds }

            # Esc + anything but '[' is a meta key -- Alt+m again, to toggle back
            # off. Settle already drained the trigger's auto-repeat, so this can
            # only be a fresh press. End the capture; it is already consumed, so
            # nothing leaks into the line and the handler will not re-fire.
            if ($seq.Length -eq 2 -and $ch -ne '[') { break }

            # After "ESC [", the first byte in 0x40-0x7E closes the sequence.
            if ($seq.Length -lt 3 -or $ch -lt [char]0x40 -or $ch -gt [char]0x7E) { continue }

            # SGR report: ESC [ < flags ; col ; row (M press | m release).
            # -cmatch, not -match: 'M' and 'm' are the only thing telling the two
            # apart, and -match ignores case.
            $report = $seq
            $seq = ''

            # Some other CSI: an arrow, Home, a function key. It is already eaten,
            # so there is nothing to hand back -- end the capture rather than
            # silently swallow the key and leave the user pressing it again.
            if ($report -cnotmatch "^${ESC}\[<(\d+);(\d+);(\d+)([Mm])$") { break }

            $flags   = [int]$Matches[1]
            $column  = [int]$Matches[2] - 1
            $row     = [int]$Matches[3] - 1
            $pressed = $Matches[4] -ceq 'M'

            if ($flags -band 0x40) { continue }         # wheel
            $moving = [bool]($flags -band 0x20)         # drag step

            # Low 2 bits are the button. 0x04/0x08/0x10 are shift/alt/ctrl held at
            # click time -- a click with Alt still down reports 8, not 0.
            $button = $flags -band 0x03

            if (-not $moving) { $dragging = $pressed }
            if ($moving -and -not $dragging) { continue }
            if (-not $pressed -and -not $moving) { continue }   # button release

            [pscustomobject]@{
                Column = $column
                Row    = $row
                Button = $button
            }
            $sw.Restart()   # the timeout is for going idle, not for the capture
        }
    } finally {
        Write-ConsoleVT "${ESC}[?1000;1002;1006l"

        # Mouse reports still in flight would land in the line as text once the
        # mode is back, so eat those -- and ONLY those. Anything that does not
        # start with Esc is the user's keystroke and has to survive: it may be the
        # very key that ended the capture.
        Start-Sleep -Milliseconds 30
        while ([ConsoleInput]::PeekChar($handle) -eq [int][char]27) {
            [ConsoleInput]::Consume($handle)
            # Take the rest of the sequence: up to its final byte (0x40-0x7E).
            while ($true) {
                $code = [ConsoleInput]::PeekChar($handle)
                if ($code -lt 0) { break }
                [ConsoleInput]::Consume($handle)
                if ($code -ge 0x40 -and $code -le 0x7E -and $code -ne [int][char]'[') { break }
            }
        }

        [void][WinApi]::SetConsoleMode($handle, $oldMode)
    }
}
