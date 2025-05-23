﻿<#
.SYNOPSIS
	Lists the current working directory
.DESCRIPTION
	This PowerShell script lists the path to current working directory (but not the content itself).
.EXAMPLE
	PS> ./list-workdir.ps1
	📂C:\Users\Markus
.LINK
	https://github.com/fleschutz/PowerShell
.NOTES
	Author: Markus Fleschutz | License: CC0
#>

try {
	$Path = Resolve-Path -Path "$PWD"
	"📂$Path"
	exit 0 # success
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}