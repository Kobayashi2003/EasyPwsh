<#
.SYNOPSIS
    Automates Internet Explorer using COM automation.
.DESCRIPTION
    This script provides automation capabilities for Internet Explorer,
    including navigation, form filling, and content extraction.
.PARAMETER Action
    The action to perform: Navigate, Screenshot, Extract, Submit
.PARAMETER URL
    The URL to navigate to or interact with
.PARAMETER FormData
    Hashtable containing form field IDs and values for form submission
.PARAMETER OutputPath
    Path where to save output (screenshots, extracted content)
.EXAMPLE
    PS> ./Invoke-IEAutomation.ps1 -Action Navigate -URL "https://example.com"
.EXAMPLE
    PS> ./Invoke-IEAutomation.ps1 -Action Submit -URL "https://example.com/form" -FormData @{
        "username" = "user";
        "password" = "pass"
    }
.NOTES
    This script requires Internet Explorer to be installed.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Navigate", "Screenshot", "Extract", "Submit")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$URL,

    [Parameter()]
    [hashtable]$FormData,

    [Parameter()]
    [string]$OutputPath
)

function Wait-ForIEReady {
    param($IE)
    while ($IE.Busy -or $IE.ReadyState -ne 4) {
        Start-Sleep -Milliseconds 100
    }
}

function Take-Screenshot {
    param($IE, $Path)

    # Create Word application for screenshot capability
    $word = New-Object -ComObject Word.Application
    $word.Visible = $false

    # Send Alt+PrintScreen
    $shell = New-Object -ComObject WScript.Shell
    $IE.Navigate2($URL)
    Wait-ForIEReady -IE $IE
    $shell.SendKeys("%{PRTSC}")

    # Create new document and paste
    $doc = $word.Documents.Add()
    $word.Selection.Paste()

    # Save as PNG
    $doc.SaveAs([ref]$Path, [ref]19) # 19 = PNG format
    $doc.Close()
    $word.Quit()

    # Cleanup
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($word) | Out-Null
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
}

try {
    $ie = New-Object -ComObject InternetExplorer.Application
    $ie.Visible = $true

    switch ($Action) {
        "Navigate" {
            $ie.Navigate2($URL)
            Wait-ForIEReady -IE $ie
            Write-Host "Navigated to: $URL"
        }

        "Screenshot" {
            if (-not $OutputPath) {
                throw "OutputPath parameter is required for Screenshot action"
            }

            $ie.Navigate2($URL)
            Wait-ForIEReady -IE $ie
            Take-Screenshot -IE $ie -Path $OutputPath
            Write-Host "Screenshot saved to: $OutputPath"
        }

        "Extract" {
            $ie.Navigate2($URL)
            Wait-ForIEReady -IE $ie

            # Extract page content
            $content = $ie.Document.body.innerText

            if ($OutputPath) {
                $content | Out-File -FilePath $OutputPath
                Write-Host "Content saved to: $OutputPath"
            } else {
                Write-Host "Page content:"
                Write-Host $content
            }
        }

        "Submit" {
            if (-not $FormData) {
                throw "FormData parameter is required for Submit action"
            }

            $ie.Navigate2($URL)
            Wait-ForIEReady -IE $ie

            # Fill form fields
            foreach ($field in $FormData.GetEnumerator()) {
                $element = $ie.Document.getElementById($field.Key)
                if ($element) {
                    $element.value = $field.Value
                } else {
                    Write-Warning "Form field not found: $($field.Key)"
                }
            }

            # Submit form (assumes form has id="submitButton")
            $submitButton = $ie.Document.getElementById("submitButton")
            if ($submitButton) {
                $submitButton.click()
                Wait-ForIEReady -IE $ie
                Write-Host "Form submitted successfully"
            } else {
                Write-Warning "Submit button not found"
            }
        }
    }

    # Cleanup
    $ie.Quit()
    [System.Runtime.Interopservices.Marshal]::ReleaseComObject($ie) | Out-Null
}
catch {
    Write-Error "Failed to perform IE automation: $_"
    if ($ie) {
        $ie.Quit()
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($ie) | Out-Null
    }
}