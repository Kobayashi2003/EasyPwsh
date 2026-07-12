# -EnableFd, -AltCCommand and -EnableAliasFuzzyScoop only exist in PSFzf 2.5+, and
# an unknown switch is a hard parameter error. Probe what this version supports.
$__psfzf_options = (Get-Command Set-PsFzfOption).Parameters.Keys

# Select Current Provider Path (default chord: `Ctrl+t`)
# Reverse Search Through PSReadline History (default chord: `Ctrl+r`)
Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'

# Set-Location Based on Selected Directory (default chord: `Alt+c`)
# example command - use $Location with a different command:
if ($__psfzf_options -contains 'AltCCommand') {
    $commandOverride = [ScriptBlock]{ param($Location) Write-Host $Location }
    # pass your override to PSFzf:
    Set-PsFzfOption -AltCCommand $commandOverride
}

# Search Through Command Line Arguments in PSReadline History (default chord: `Alt+a`)
# NOTE: modules\module.PSReadLine.ps1 also binds Alt+a (SelectCommandArguments).
# Whichever module is imported last wins, so enabling PSFzf takes Alt+a over.
Set-PSReadLineKeyHandler -Key Alt+a -ScriptBlock { Invoke-FuzzyHistory }

Set-PsFzfOption -TabExpansion

if ($__psfzf_options -contains 'EnableFd') { Set-PSFzfOption -EnableFd }

Set-PSFzfOption -EnableAliasFuzzyEdit           # fe
Set-PSFzfOption -EnableAliasFuzzyFasd           # ff
Set-PSFzfOption -EnableAliasFuzzyZLocation      # fz
Set-PSFzfOption -EnableAliasFuzzyGitStatus      # fgs
Set-PSFzfOption -EnableAliasFuzzyHistory        # fh
Set-PSFzfOption -EnableAliasFuzzyKillProcess    # fkill
Set-PSFzfOption -EnableAliasFuzzySetLocation    # fd  (shadows the fd executable)
Set-PSFzfOption -EnableAliasFuzzySetEverything  # cde

if ($__psfzf_options -contains 'EnableAliasFuzzyScoop') { Set-PSFzfOption -EnableAliasFuzzyScoop }  # fs
