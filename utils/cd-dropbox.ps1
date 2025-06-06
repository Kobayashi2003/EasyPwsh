﻿<#
.SYNOPSIS
	Sets the working directory to the user's Dropbox folder
.DESCRIPTION
	This PowerShell script changes the working directory to the user's Dropbox folder.
.EXAMPLE
	PS> ./cd-dropbox
	📂C:\Users\Markus\Dropbox
.LINK
	https://github.com/fleschutz/PowerShell
.NOTES
	Author: Markus Fleschutz | License: CC0
#>

try {
	$Path = Resolve-Path "$HOME/Dropbox"
	if (-not(Test-Path "$Path" -pathType container)) {
		throw "Dropbox folder at 📂$Path doesn't exist (yet)"
	}
	Set-Location "$Path"
	"📂$Path"
	exit 0 # sucess
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}