function Get-EasyPwshMvUndoLogPath {
    $baseDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'EasyPwsh\undo'
    if (-not (Test-Path -LiteralPath $baseDir)) {
        New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    }
    Join-Path -Path $baseDir -ChildPath 'mv-ops.jsonl'
}

function Clear-EasyPwshMvUndoLog {
    $logPath = Get-EasyPwshMvUndoLogPath
    if (Test-Path -LiteralPath $logPath) {
        Clear-Content -LiteralPath $logPath
    }
}

function Add-EasyPwshMvUndoRecord {
    param(
        [Parameter(Mandatory)]
        [string]$From,
        [Parameter(Mandatory)]
        [string]$To,
        [Parameter(Mandatory)]
        [ValidateSet('File', 'Directory')]
        [string]$ItemType
    )

    $record = [ordered]@{
        id       = [Guid]::NewGuid().ToString('D')
        ts       = (Get-Date).ToString('o')
        op       = 'mv'
        from     = $From
        to       = $To
        itemType = $ItemType
        cwd      = (Get-Location).Path
    }

    $logPath = Get-EasyPwshMvUndoLogPath
    ($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $logPath -Encoding UTF8
}

function Get-EasyPwshMvUndoLastRecord {
    $logPath = Get-EasyPwshMvUndoLogPath
    if (-not (Test-Path -LiteralPath $logPath)) {
        return $null
    }
    $lastLine = Get-Content -LiteralPath $logPath -Tail 1 -ErrorAction SilentlyContinue
    if (-not $lastLine) {
        return $null
    }
    try {
        return ($lastLine | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Remove-EasyPwshMvUndoLastRecord {
    $logPath = Get-EasyPwshMvUndoLogPath
    if (-not (Test-Path -LiteralPath $logPath)) {
        return
    }
    $lines = Get-Content -LiteralPath $logPath -ErrorAction Stop
    if (-not $lines -or $lines.Count -le 1) {
        Clear-Content -LiteralPath $logPath
        return
    }
    Set-Content -LiteralPath $logPath -Value $lines[0..($lines.Count - 2)] -Encoding UTF8
}

function Move-ItemSafely {
    <#
    .SYNOPSIS
        Move an item, with undo logging.
    .DESCRIPTION
        Logs successful operations to a local undo log so you can run: undo-fs
        Note: this does NOT integrate with Windows Explorer's global undo stack.
    .EXAMPLE
        mv C:\temp\a.txt D:\dest\
    .EXAMPLE
        mv C:\temp\a.txt D:\dest\b.txt
    #>

    [CmdletBinding(DefaultParameterSetName = 'Move', SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(ParameterSetName = 'Move', Mandatory, Position = 0)]
        [string]$From,
        [Parameter(ParameterSetName = 'Move', Mandatory, Position = 1)]
        [string]$To,
        [Parameter(ParameterSetName = 'Move')]
        [switch]$Force,

        [Parameter(ParameterSetName = 'Undo', Mandatory)]
        [switch]$Undo
    )

    if ($PSCmdlet.ParameterSetName -eq 'Undo') {
        $record = Get-EasyPwshMvUndoLastRecord
        if (-not $record) {
            throw 'No mv undo record found.'
        }

        $from = [string]$record.from
        $to = [string]$record.to
        if (-not $from -or -not $to) {
            throw 'Last mv undo record is invalid.'
        }

        # Backward-compatibility: if an old record stored a directory as destination for a file move.
        if ($record.itemType -eq 'File' -and (Test-Path -LiteralPath $to -PathType Container)) {
            $leafName = Split-Path -Path $from -Leaf
            $to = Join-Path -Path $to -ChildPath $leafName
        }

        if (-not (Test-Path -LiteralPath $to)) {
            throw "Cannot undo: current path does not exist: '$to'"
        }

        if (Test-Path -LiteralPath $from) {
            throw "Cannot undo: original path already exists: '$from'"
        }

        if ($PSCmdlet.ShouldProcess($to, "Undo mv: move back to '$from'")) {
            Move-Item -LiteralPath $to -Destination $from -ErrorAction Stop
            Remove-EasyPwshMvUndoLastRecord
            return $record
        }

        return
    }

    $fromItem = Get-Item -LiteralPath $From -ErrorAction Stop
    $fromFull = $fromItem.FullName
    $itemType = if ($fromItem.PSIsContainer) { 'Directory' } else { 'File' }

    if ((Get-Location).Provider.Name -ne 'FileSystem') {
        throw "mv only supports FileSystem locations (current provider: $((Get-Location).Provider.Name))."
    }

    # Important: don't use [System.IO.Path]::GetFullPath here.
    # It resolves relative paths (like '.') against the process working directory, which can differ from PowerShell's current location.
    $toFull = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($To)

    if ($PSCmdlet.ShouldProcess($fromFull, "Move to '$toFull'")) {
        $moved = Move-Item -LiteralPath $fromFull -Destination $toFull -Force:$Force -PassThru -ErrorAction Stop
        $toActual = if ($null -ne $moved -and $null -ne $moved.FullName) { $moved.FullName } else { $toFull }
        Add-EasyPwshMvUndoRecord -From $fromFull -To $toActual -ItemType $itemType
    }
}

# Override the built-in mv alias (Move-Item)
Set-Alias -Name 'mv' -Value 'Move-ItemSafely' -Force -Option AllScope
