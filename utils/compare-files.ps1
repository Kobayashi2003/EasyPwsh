#
<#
.SYNOPSIS
    Compares the contents of two files with color-coded differences
.DESCRIPTION
    This PowerShell script compares two files line by line and shows differences with color coding:
    - Green: Lines that exist only in source file
    - Red: Lines that exist only in target file
    - Yellow: Lines that are similar but have differences
.PARAMETER SourcePath
    Specifies the source file path
.PARAMETER TargetPath
    Specifies the target file path
.PARAMETER Context
    Specifies how many lines of context to show around differences (default: 3)
.PARAMETER ShowOnly
    Specifies which differences to show: 'All' (default), 'OnlyInSource', 'OnlyInTarget', 'Different'
.EXAMPLE
    PS> ./compare-files.ps1 C:\source.txt D:\target.txt
.EXAMPLE
    PS> ./compare-files.ps1 -SourcePath "C:\source.txt" -TargetPath "D:\target.txt" -Context 5 -ShowOnly "Different"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$TargetPath,

    [Parameter(Mandatory = $false)]
    [int]$Context = 3,

    [Parameter(Mandatory = $false)]
    [ValidateSet('All', 'OnlyInSource', 'OnlyInTarget', 'Different')]
    [string]$ShowOnly = 'All'
)

function Get-StringSimilarity {
    param (
        [string]$str1,
        [string]$str2
    )

    # Simple Levenshtein Distance implementation
    $len1 = $str1.Length
    $len2 = $str2.Length

    # Initialize matrix
    $matrix = New-Object 'int[,]' ($len1 + 1), ($len2 + 1)

    # Fill first row and column
    for ($i = 0; $i -le $len1; $i++) { $matrix[$i, 0] = $i }
    for ($j = 0; $j -le $len2; $j++) { $matrix[0, $j] = $j }

    # Fill rest of matrix
    for ($i = 1; $i -le $len1; $i++) {
        for ($j = 1; $j -le $len2; $j++) {
            $cost = if ($str1[$i - 1] -eq $str2[$j - 1]) { 0 } else { 1 }
            $matrix[$i, $j] = [Math]::Min(
                [Math]::Min(
                    $matrix[($i - 1), $j] + 1,      # Deletion
                    $matrix[$i, ($j - 1)] + 1       # Insertion
                ),
                $matrix[($i - 1), ($j - 1)] + $cost # Substitution
            )
        }
    }

    # Return similarity score (0 to 1, where 1 is exact match)
    $maxLen = [Math]::Max($len1, $len2)
    if ($maxLen -eq 0) { return 1.0 }
    return 1.0 - ($matrix[$len1, $len2] / $maxLen)
}

function Write-LineWithContext {
    param (
        [string[]]$lines,
        [int]$currentIndex,
        [int]$context,
        [string]$prefix = "",
        [System.ConsoleColor]$color = [System.ConsoleColor]::White
    )

    $startLine = [Math]::Max(0, $currentIndex - $context)
    $endLine = [Math]::Min($lines.Length - 1, $currentIndex + $context)

    for ($i = $startLine; $i -le $endLine; $i++) {
        if ($i -eq $currentIndex) {
            Write-Host "$prefix$($i + 1): $($lines[$i])" -ForegroundColor $color
        } else {
            Write-Host "  $($i + 1): $($lines[$i])" -ForegroundColor Gray
        }
    }
}

try {
    # Validate paths
    if (-not (Test-Path -Path $SourcePath -PathType Leaf)) {
        throw "Source file does not exist: $SourcePath"
    }
    if (-not (Test-Path -Path $TargetPath -PathType Leaf)) {
        throw "Target file does not exist: $TargetPath"
    }

    # Convert to absolute paths
    $SourcePath = (Resolve-Path $SourcePath).Path
    $TargetPath = (Resolve-Path $TargetPath).Path

    Write-Host "Comparing files..."
    Write-Host "Source: $SourcePath"
    Write-Host "Target: $TargetPath"
    Write-Host "Context lines: $Context"
    Write-Host "Show: $ShowOnly"
    Write-Host ""

    # Read files
    $sourceLines = Get-Content $SourcePath
    $targetLines = Get-Content $TargetPath

    # Create arrays to track matched lines
    $sourceMatched = New-Object bool[] $sourceLines.Length
    $targetMatched = New-Object bool[] $targetLines.Length

    # First pass: Find exact matches and very similar lines
    for ($i = 0; $i -lt $sourceLines.Length; $i++) {
        $sourceLine = $sourceLines[$i]
        $bestMatch = -1
        $bestSimilarity = 0.8 # Threshold for considering lines similar

        for ($j = 0; $j -lt $targetLines.Length; $j++) {
            if (-not $targetMatched[$j]) {
                $similarity = Get-StringSimilarity $sourceLine $targetLines[$j]
                if ($similarity -eq 1.0) {
                    $sourceMatched[$i] = $true
                    $targetMatched[$j] = $true
                    break
                }
                elseif ($similarity -gt $bestSimilarity) {
                    $bestSimilarity = $similarity
                    $bestMatch = $j
                }
            }
        }

        # If we found a similar line, mark it
        if (-not $sourceMatched[$i] -and $bestMatch -ge 0) {
            if ($ShowOnly -in @('All', 'Different')) {
                Write-Host "`nSimilar lines:" -ForegroundColor Yellow
                Write-LineWithContext $sourceLines $i $Context "- " Yellow
                Write-LineWithContext $targetLines $bestMatch $Context "+ " Yellow
            }
            $sourceMatched[$i] = $true
            $targetMatched[$bestMatch] = $true
        }
    }

    # Show unmatched lines from source
    if ($ShowOnly -in @('All', 'OnlyInSource')) {
        $hasUnmatched = $false
        for ($i = 0; $i -lt $sourceLines.Length; $i++) {
            if (-not $sourceMatched[$i]) {
                if (-not $hasUnmatched) {
                    Write-Host "`nOnly in source file:" -ForegroundColor Green
                    $hasUnmatched = $true
                }
                Write-LineWithContext $sourceLines $i $Context "- " Green
            }
        }
    }

    # Show unmatched lines from target
    if ($ShowOnly -in @('All', 'OnlyInTarget')) {
        $hasUnmatched = $false
        for ($i = 0; $i -lt $targetLines.Length; $i++) {
            if (-not $targetMatched[$i]) {
                if (-not $hasUnmatched) {
                    Write-Host "`nOnly in target file:" -ForegroundColor Red
                    $hasUnmatched = $true
                }
                Write-LineWithContext $targetLines $i $Context "+ " Red
            }
        }
    }

    exit 0 # success
} catch {
    "⚠️ Error in line $($_.InvocationInfo.ScriptLineNumber): $($Error[0])"
    exit 1
}