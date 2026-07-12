<#
.SYNOPSIS
	Configures the global Git identity, line-ending policy and SSH key
.DESCRIPTION
	This PowerShell script applies the global Git settings a new machine needs before
	it can push: the commit identity, the cross-platform newline policy, and an SSH
	key registered with the remote.

	Existing values are shown and kept unless a new one is supplied, so the script is
	safe to run again. Left at its default, -autocrlf turns the automatic newline
	conversion off, which is what a repository shared with Linux build machines wants:
	with it on, Git rewrites line endings on checkout and the build sees spurious diffs.
.PARAMETER name
	The commit author name written to user.name (asks interactively by default)
.PARAMETER email
	The commit author address written to user.email (asks interactively by default)
.PARAMETER autocrlf
	The core.autocrlf value: false (default), true, or input
.PARAMETER noSshKey
	Skips the SSH key check entirely
.PARAMETER keyType
	The key type passed to ssh-keygen when one has to be created, ed25519 by default
.EXAMPLE
	PS> ./set-git-config.ps1
	✔️ Git configured for Jane Doe <jane@example.com> (core.autocrlf=false).
.EXAMPLE
	PS> ./set-git-config.ps1 -name "Jane Doe" -email jane@example.com
.EXAMPLE
	PS> ./set-git-config.ps1 -autocrlf input -noSshKey
.LINK
	https://github.com/Kobayashi2003/EasyPwsh
.NOTES
	Author: Kobayashi | License: MIT
#>

param(
    [string]$name = "",
    [string]$email = "",

    [ValidateSet("false", "true", "input")]
    [string]$autocrlf = "false",

    [switch]$noSshKey,

    [ValidateSet("ed25519", "rsa", "ecdsa")]
    [string]$keyType = "ed25519"
)

# Read-Host blocks forever in a non-interactive host, so only ask when someone
# is actually there to answer.
function Test-Interactive {
    return [Environment]::UserInteractive -and -not [Console]::IsInputRedirected
}

function Get-GitConfig {
    param([string]$key)

    $value = (& git config --global $key) 2>$null
    return "$value".Trim()
}

try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "git.exe not found. Install it with 'scoop install git'."
    }

    $currentName = Get-GitConfig "user.name"
    $currentEmail = Get-GitConfig "user.email"

    Write-Host "ℹ️ Current identity: " -NoNewline -ForegroundColor Cyan
    Write-Host "$(if ($currentName) { $currentName } else { '<unset>' }) <$(if ($currentEmail) { $currentEmail } else { '<unset>' })>"

    if (-not $name -and (Test-Interactive)) {
        $name = (Read-Host "user.name  (Enter to keep current)").Trim()
    }
    if (-not $email -and (Test-Interactive)) {
        $email = (Read-Host "user.email (Enter to keep current)").Trim()
    }

    if ($name) { & git config --global user.name $name }
    if ($email) { & git config --global user.email $email }

    $currentName = Get-GitConfig "user.name"
    $currentEmail = Get-GitConfig "user.email"
    if (-not $currentName -or -not $currentEmail) {
        throw "user.name and user.email must both be set, otherwise Git refuses to commit"
    }

    if ((Get-GitConfig "core.autocrlf") -ne $autocrlf) {
        & git config --global core.autocrlf $autocrlf
    }

    Write-Host "✔️ Git configured for " -NoNewline -ForegroundColor Green
    Write-Host "$currentName <$currentEmail>" -NoNewline -ForegroundColor Yellow
    Write-Host " (core.autocrlf=$autocrlf)." -ForegroundColor Green

    if ($noSshKey) { exit 0 }

    # ssh-keygen names the key after its type, and the remote only cares that the
    # public half is registered, so accept whichever type already exists.
    $sshDir = Join-Path $HOME ".ssh"
    $existing = @(Get-ChildItem -LiteralPath $sshDir -Filter "id_*.pub" -File -ErrorAction SilentlyContinue)

    if ($existing.Count -gt 0) {
        $publicKey = $existing[0].FullName
        Write-Host "ℹ️ SSH key already exists: " -NoNewline -ForegroundColor Cyan
        Write-Host "$publicKey" -ForegroundColor Yellow
    }
    else {
        Write-Host "⚠️ No SSH key found. The remote needs one before it will accept a push." -ForegroundColor Yellow

        if (-not (Test-Interactive)) {
            Write-Host "ℹ️ Create one with: ssh-keygen -t $keyType" -ForegroundColor Cyan
            exit 0
        }
        if ((Read-Host "Generate one now with ssh-keygen -t $keyType? (Y/n)") -notin "", "y", "Y") {
            exit 0
        }
        if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
            throw "ssh-keygen.exe not found (it ships with Git)."
        }

        if (-not (Test-Path -LiteralPath $sshDir)) {
            New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
        }

        $privateKey = Join-Path $sshDir "id_$keyType"
        # -N "" leaves the key without a passphrase, so pushes do not stop to ask for one.
        & ssh-keygen -t $keyType -f $privateKey -N '""' -C $currentEmail

        $publicKey = "$privateKey.pub"
        if (-not (Test-Path -LiteralPath $publicKey)) {
            throw "ssh-keygen did not produce $publicKey"
        }
        Write-Host "✔️ Created $publicKey" -ForegroundColor Green
    }

    $keyContent = (Get-Content -LiteralPath $publicKey -Raw).Trim()

    Write-Host "ℹ️ Add this public key to your Git remote (Profile -> SSH Keys):" -ForegroundColor Cyan
    Write-Host "$keyContent" -ForegroundColor Yellow

    if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
        $keyContent | Set-Clipboard
        Write-Host "✔️ Copied to the clipboard." -ForegroundColor Green
    }

    exit 0 # success
}
catch {
    Write-Host "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
