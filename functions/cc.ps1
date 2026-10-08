function cc {
    if ($args[0]) { Set-Location -LiteralPath $args[0] } else { Set-Location -LiteralPath $HOME }
    if ($?) { Clear-Host }
}