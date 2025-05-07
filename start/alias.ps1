$alias_map = @{
    'l' = 'ls'
    'c' = 'clear'
    'open' = 'explorer'
}

foreach ($key in $alias_map.Keys) {
    Set-Alias -Name $key -Value $alias_map[$key] -Scope Global
}