param(
    [string]$Repository = 'C:\Users\spoon\Documents\ChatGPT\выгрузка\DnsConf-fix',
    [string]$InterfaceAlias = '',
    [int]$FailureThreshold = 3
)

$ErrorActionPreference = 'Stop'
$sourceUrl = 'https://raw.githubusercontent.com/Internet-Helper/GeoHideDNS/refs/heads/main/hosts/hosts'
$hostsPath = Join-Path $Repository 'openai-hosts'
$logDirectory = Join-Path $env:LOCALAPPDATA 'DnsConf'
$logPath = Join-Path $logDirectory 'openai-proxy-watch.log'
$failurePath = Join-Path $logDirectory 'openai-proxy-failures.txt'
$probeHosts = @('chatgpt.com', 'auth.openai.com', 'cdn.oaistatic.com', 'files.oaiusercontent.com')

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

function Get-PhysicalConnection {
    $virtualPattern = 'VPN|OpenVPN|Happ|Radmin|Fortinet|TAP|TUN|WireGuard|Amnezia|VMware|VirtualBox|Hyper-V|Bluetooth|Loopback|Wi-Fi Direct'
    $connections = foreach ($config in @(Get-NetIPConfiguration -ErrorAction Stop)) {
        if (-not $config.IPv4Address -or -not $config.IPv4DefaultGateway) { continue }
        if ($InterfaceAlias -and $config.InterfaceAlias -ne $InterfaceAlias) { continue }

        $adapter = Get-NetAdapter -InterfaceIndex $config.InterfaceIndex -ErrorAction SilentlyContinue
        if (-not $adapter -or $adapter.Status -ne 'Up' -or -not $adapter.HardwareInterface) { continue }
        if (("$($adapter.Name) $($adapter.InterfaceDescription)") -match $virtualPattern) { continue }

        $address = @($config.IPv4Address | Where-Object { $_.IPAddress -notlike '169.254.*' })[0].IPAddress
        $gateway = $config.IPv4DefaultGateway.NextHop
        if (-not $address -or -not $gateway) { continue }
        $metric = (Get-NetIPInterface -InterfaceIndex $config.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
        if ($null -eq $metric) { $metric = 9999 }
        [pscustomobject]@{
            InterfaceAlias = $config.InterfaceAlias
            InterfaceIndex = $config.InterfaceIndex
            SourceAddress = $address
            Gateway = $gateway
            Metric = [int]$metric
        }
    }
    $selected = @($connections | Sort-Object Metric, InterfaceIndex)[0]
    if (-not $selected) { throw 'No active physical Ethernet or Wi-Fi connection with an IPv4 gateway was found' }
    return $selected
}

function Get-FailureCount {
    if (-not (Test-Path -LiteralPath $failurePath)) { return 0 }
    $value = 0
    if ([int]::TryParse((Get-Content -LiteralPath $failurePath -Raw).Trim(), [ref]$value)) { return $value }
    return 0
}

function Set-FailureCount([int]$Count) {
    Set-Content -LiteralPath $failurePath -Value $Count -Encoding ascii
}

function Test-Proxy([string]$Address, [string]$SourceAddress) {
    foreach ($hostName in $probeHosts) {
        $client = [System.Net.Sockets.TcpClient]::new([System.Net.Sockets.AddressFamily]::InterNetwork)
        try {
            $client.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($SourceAddress), 0))
            $connect = $client.ConnectAsync($Address, 443)
            if (-not $connect.Wait(5000) -or -not $client.Connected) { return $false }

            $client.ReceiveTimeout = 8000
            $client.SendTimeout = 8000
            $stream = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
            $auth = $stream.AuthenticateAsClientAsync($hostName)
            if (-not $auth.Wait(5000) -or -not $stream.IsAuthenticated) { return $false }

            if ($hostName -eq 'chatgpt.com') {
                $request = "GET /cdn-cgi/trace HTTP/1.1`r`nHost: chatgpt.com`r`nUser-Agent: Mozilla/5.0`r`nConnection: close`r`n`r`n"
                $requestBytes = [System.Text.Encoding]::ASCII.GetBytes($request)
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()

                $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
                $response = $reader.ReadToEnd()
                $location = [regex]::Match($response, '(?m)^loc=([A-Z]{2})\r?$').Groups[1].Value
                if ($response -notmatch '^HTTP/1\.1 200' -or -not $location -or $location -in @('RU', 'BY')) {
                    return $false
                }
            }
            $stream.Dispose()
        }
        catch {
            return $false
        }
        finally {
            $client.Dispose()
        }
    }
    return $true
}

try {
    $connection = Get-PhysicalConnection
    $sourceAddress = $connection.SourceAddress
    $currentAddress = (Get-Content -LiteralPath $hostsPath |
        Where-Object { $_ -match '^\s*\d{1,3}(?:\.\d{1,3}){3}\s+' } |
        Select-Object -First 1) -replace '\s+.*$', ''

    $currentHealthy = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        if ($currentAddress -and (Test-Proxy $currentAddress $sourceAddress)) {
            $currentHealthy = $true
            break
        }
        Write-Log "PROBE FAILED: $currentAddress attempt $attempt/3"
        if ($attempt -lt 3) { Start-Sleep -Seconds 3 }
    }
    if ($currentHealthy) {
        Set-FailureCount 0
        Write-Log "OK: $currentAddress via $($connection.InterfaceAlias) ($sourceAddress)"
        exit 0
    }

    $failureCount = (Get-FailureCount) + 1
    Set-FailureCount $failureCount
    if ($failureCount -lt $FailureThreshold) {
        Write-Log "DEGRADED: $currentAddress via $($connection.InterfaceAlias); consecutive failure $failureCount/$FailureThreshold, keeping current address"
        exit 0
    }

    Write-Log "FAILED: $currentAddress for $failureCount consecutive runs; looking for replacement"
    $source = (Invoke-WebRequest -UseBasicParsing -Uri $sourceUrl -TimeoutSec 20).Content
    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($source -split "`n")) {
        if ($line -match '^#\s*(\d{1,3}(?:\.\d{1,3}){3})\s*$') {
            $candidate = $Matches[1]
            if (-not $candidates.Contains($candidate)) { $candidates.Add($candidate) }
        }
    }

    $replacement = $null
    foreach ($candidate in $candidates) {
        if ($candidate -ne $currentAddress -and (Test-Proxy $candidate $sourceAddress) -and (Test-Proxy $candidate $sourceAddress)) {
            $replacement = $candidate
            break
        }
    }
    if (-not $replacement) { throw 'No working OpenAI proxy found' }

    $env:GIT_TERMINAL_PROMPT = '0'
    & git -C $Repository pull --ff-only origin main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git pull failed' }

    $updated = Get-Content -LiteralPath $hostsPath | ForEach-Object {
        if ($_ -match '^# OpenAI/ChatGPT overrides verified') {
            "# OpenAI/ChatGPT overrides verified via physical network on $(Get-Date -Format yyyy-MM-dd)"
        }
        elseif ($_ -match '^\s*\d{1,3}(?:\.\d{1,3}){3}(\s+.+)$') {
            "$replacement$($Matches[1])"
        }
        else { $_ }
    }
    Set-Content -LiteralPath $hostsPath -Value $updated -Encoding utf8

    & git -C $Repository add openai-hosts
    & git -C $Repository commit -m "Rotate OpenAI proxy to $replacement" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed' }
    & git -C $Repository push origin main | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'git push failed' }

    Set-FailureCount 0
    Clear-DnsClientCache
    Write-Log "UPDATED: $currentAddress -> $replacement; DNS cache cleared"
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
