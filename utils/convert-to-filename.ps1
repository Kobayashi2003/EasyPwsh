# Convert a string to a valid Windows filename by replacing illegal characters
# with visually similar Unicode alternatives.
#
# Illegal character mappings (fullwidth lookalikes):
#   \  →  ＼   /  →  ／   :  →  ：   *  →  ＊   ?  →  ？
#   "  →  ＂   <  →  ＜   >  →  ＞   |  →  ｜
#   \n / \r  →  _

param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
    [string]$InputString
)

process {
    $result = $InputString `
        -replace "`r`n|`r|`n", '_' `
        -replace '\\',          '＼' `
        -replace '/',           '／' `
        -replace ':',           '：' `
        -replace '\*',          '＊' `
        -replace '\?',          '？' `
        -replace '"',           '＂' `
        -replace '<',           '＜' `
        -replace '>',           '＞' `
        -replace '\|',          '｜'

    Set-Clipboard -Value $result
    $result
}
