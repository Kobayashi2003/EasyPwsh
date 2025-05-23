<#
.SYNOPSIS
	Lists the user groups
.DESCRIPTION
	This PowerShell script lists the user groups of the local computer.
.EXAMPLE
	PS> ./list-user-groups.ps1

	Name                 Description
	----                 -----------
	Administrators       Administrators have complete and unrestricted access to the computer/domain
	...
.LINK
	https://github.com/fleschutz/PowerShell
.NOTES
	Author: Markus Fleschutz | License: CC0
#>

try {
	Get-LocalGroup
	exit 0 # success
} catch {
	"⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
	exit 1
}