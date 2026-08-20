function portkill {

<#
    .SYNOPSIS
        Kills the processes that occupy the given port(s)
    .DESCRIPTION
        Looks up which process is holding a local port and stops it, so the port
        can be reused. TCP listeners are matched by default; use -Protocol to
        include UDP endpoints and -AllStates to match non-listening TCP sockets
        (established, time-wait, ...) as well.

        Falls back to parsing `netstat -ano` when the NetTCPIP cmdlets are not
        available (Windows PowerShell on older builds, Server Core, ...).
    .PARAMETER Port
        One or more local ports to free
    .PARAMETER Protocol
        Which protocol to look at: TCP (default), UDP or Any
    .PARAMETER AllStates
        Also match TCP sockets that are not in the Listen state
    .PARAMETER List
        Only report the owning processes, kill nothing
    .PARAMETER Force
        Kill without asking for confirmation
    .EXAMPLE
        portkill 3000
    .EXAMPLE
        portkill 8080, 5173 -Force
    .EXAMPLE
        portkill 53 -Protocol Any -List
#>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidateRange(1, 65535)]
        [int[]]$Port,

        [ValidateSet('TCP', 'UDP', 'Any')]
        [string]$Protocol = 'TCP',

        [switch]$AllStates,
        [switch]$List,
        [switch]$Force
    )

    begin {
        # PID 0 is the idle process, PID 4 is the kernel; both would blue-screen
        # the box (or simply refuse), and killing ourselves ends the session.
        $protectedIds = @(0, 4, $PID)

        $useNetCmdlets = [bool](Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)

        function Get-PortOwnerFromNetstat($portNumber, $wantedProtocol) {
            netstat -ano | ForEach-Object {
                $fields = $_.Trim() -split '\s+'
                if ($fields.Count -lt 4) { return }

                $proto = $fields[0].ToUpper()
                if ($proto -ne 'TCP' -and $proto -ne 'UDP') { return }
                if ($wantedProtocol -ne 'Any' -and $proto -ne $wantedProtocol) { return }

                # Local address is either 0.0.0.0:80 or [::]:80
                if ($fields[1] -notmatch ':(\d+)$' -or [int]$Matches[1] -ne $portNumber) { return }

                $state = if ($proto -eq 'TCP' -and $fields.Count -ge 5) { $fields[3] } else { '' }
                if ($proto -eq 'TCP' -and -not $AllStates -and $state -ne 'LISTENING') { return }

                [PSCustomObject]@{
                    Protocol     = $proto
                    LocalAddress = $fields[1]
                    State        = $state
                    ProcessId    = [int]$fields[-1]
                }
            }
        }

        function Get-PortOwner($portNumber, $wantedProtocol) {
            if (-not $useNetCmdlets) {
                return Get-PortOwnerFromNetstat $portNumber $wantedProtocol
            }

            $found = @()

            if ($wantedProtocol -in 'TCP', 'Any') {
                $tcpParams = @{ LocalPort = $portNumber; ErrorAction = 'SilentlyContinue' }
                if (-not $AllStates) { $tcpParams['State'] = 'Listen' }
                $found += Get-NetTCPConnection @tcpParams | ForEach-Object {
                    [PSCustomObject]@{
                        Protocol     = 'TCP'
                        LocalAddress = "$($_.LocalAddress):$($_.LocalPort)"
                        State        = [string]$_.State
                        ProcessId    = [int]$_.OwningProcess
                    }
                }
            }

            if ($wantedProtocol -in 'UDP', 'Any') {
                $found += Get-NetUDPEndpoint -LocalPort $portNumber -ErrorAction SilentlyContinue | ForEach-Object {
                    [PSCustomObject]@{
                        Protocol     = 'UDP'
                        LocalAddress = "$($_.LocalAddress):$($_.LocalPort)"
                        State        = ''
                        ProcessId    = [int]$_.OwningProcess
                    }
                }
            }

            $found
        }
    }

    process {
        foreach ($p in $Port) {
            $owners = @(Get-PortOwner $p $Protocol)

            if (-not $owners) {
                Write-Host "Port $p is free ($Protocol)." -ForegroundColor DarkGray
                continue
            }

            # One process can hold several sockets on the same port
            foreach ($group in ($owners | Group-Object ProcessId)) {
                $processId = [int]$group.Name
                $socket = $group.Group[0]
                $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
                $name = if ($process) { $process.ProcessName } else { '<unknown>' }

                if ($List) {
                    [PSCustomObject]@{
                        Port         = $p
                        Protocol     = $socket.Protocol
                        LocalAddress = $socket.LocalAddress
                        State        = $socket.State
                        ProcessId    = $processId
                        ProcessName  = $name
                        Path         = if ($process) { $process.Path } else { $null }
                    }
                    continue
                }

                if ($processId -in $protectedIds) {
                    Write-Host "Skipping PID $processId ($name) on port $p - protected process." -ForegroundColor Yellow
                    continue
                }

                if (-not $process) {
                    Write-Host "Port $p is held by PID $processId, which is already gone." -ForegroundColor DarkGray
                    continue
                }

                $target = "$name (PID $processId) on $($socket.Protocol) port $p"
                if ($Force -or $PSCmdlet.ShouldProcess($target, 'Stop process')) {
                    try {
                        Stop-Process -Id $processId -Force -ErrorAction Stop
                        Write-Host "Killed $target." -ForegroundColor Green
                    } catch {
                        Write-Host "Failed to kill $target : $($_.Exception.Message)" -ForegroundColor Red
                        Write-Host "Try again from an elevated shell (see 'admin')." -ForegroundColor DarkGray
                    }
                }
            }
        }
    }
}

Set-Alias -Name killport -Value portkill
