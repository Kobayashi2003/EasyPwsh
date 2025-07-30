# dynv6 IPv6 Auto Update Script
# Automatically detects IPv6 address changes and updates dynv6 DNS records

param(
    [string]$Hostname = "kobayashi28.dynv6.net",
    [string]$Token = "yjg_z7wacmRxf3q7NcRxJ8k9ebv8iu",
    [int]$Netmask = 64
)

# Set temporary file path
$TempFile = Join-Path $env:TEMP "dynv6_ipv6.txt"

# Get previously recorded IP address
$OldIP = $null
if (Test-Path $TempFile) {
    $OldIP = Get-Content $TempFile -ErrorAction SilentlyContinue
}

Write-Host "Detecting IPv6 address..." -ForegroundColor Yellow

try {
    # Get current native IPv6 public address
    $IPv6Addresses = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
                     Where-Object {
                         $_.IPAddress -notlike "fe80::*" -and     # Exclude link-local
                         $_.IPAddress -notlike "::1" -and         # Exclude loopback
                         $_.IPAddress -notlike "2001:0:*" -and    # Exclude Teredo
                         $_.AddressState -eq "Preferred"          # Only preferred addresses
                     }

    if ($IPv6Addresses.Count -eq 0) {
        Write-Host "No available native IPv6 address found" -ForegroundColor Red
        Write-Host "Please ensure you have a native IPv6 connection" -ForegroundColor Yellow
        exit 1
    }

    # Use the first available native IPv6 address
    $CurrentIPv6 = $IPv6Addresses[0].IPAddress
    $CurrentIP = "$CurrentIPv6/$Netmask"

    Write-Host "Current IPv6 address: $CurrentIP (Native)" -ForegroundColor Green
    Write-Host "Previous recorded address: $OldIP" -ForegroundColor Cyan

    # Compare if IP address has changed
    if ($OldIP -ne $CurrentIP) {
        Write-Host "IP address has changed, updating DNS record..." -ForegroundColor Yellow

        # Build API request URL
        $ApiUrl = "http://dynv6.com/api/update?hostname=$Hostname&ipv6=$CurrentIP&token=$Token"

        # Send update request
        $Response = Invoke-RestMethod -Uri $ApiUrl -Method Get -ErrorAction Stop

        # Save new IP to temporary file
        $CurrentIP | Out-File $TempFile -Encoding UTF8

        Write-Host "DNS record updated successfully!" -ForegroundColor Green
        Write-Host "Response: $Response" -ForegroundColor Gray

        # Log the update
        $LogMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - IPv6 address updated: $CurrentIP"
        $LogFile = Join-Path $env:TEMP "dynv6_update.log"
        $LogMessage | Out-File $LogFile -Append -Encoding UTF8

    } else {
        Write-Host "IP address has not changed, no update needed" -ForegroundColor Gray
    }

} catch {
    Write-Host "Update failed: $($_.Exception.Message)" -ForegroundColor Red

    # Log error
    $ErrorMessage = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Update failed: $($_.Exception.Message)"
    $LogFile = Join-Path $env:TEMP "dynv6_update.log"
    $ErrorMessage | Out-File $LogFile -Append -Encoding UTF8

    exit 1
}

Write-Host "Script execution completed" -ForegroundColor Green
