function List-Albums {
    param([string]$Path = ".")

    $folders = Get-ChildItem -Path $Path -File

    if ($folders.Count -eq 0) {
        Write-Host "No folders found" -ForegroundColor Yellow
        return
    }

    $results = @()

    foreach ($folder in $folders) {
        $name = $folder.Name
        $number = ""
        $workName = ""
        $albumName = ""

        if ($name -match '^(\[[^\[\]]*\])(.*)$') {
            $number = $matches[1] -replace '[\[\]]', ''
            $remaining = $matches[2]
        } else {
            $remaining = $name
        }

        if ($remaining -match '^「([^」]*)」(.*)$') {
            $workName = $matches[1]
            $albumName = $matches[2]
        } else {
            $albumName = $remaining
        }

        $albumName = $albumName -replace '.txt', ''

        $results += [PSCustomObject]@{
            Number = $number
            WorkName = $workName
            AlbumName = $albumName.Trim()
        }
    }

    return $results
}

List-Albums