param(
    [string]$Repository = 'C:\Users\spoon\Documents\ChatGPT\выгрузка\DnsConf-fix',
    [string]$InterfaceAlias = 'Ethernet'
)

$ErrorActionPreference = 'Stop'
$sourceUrl = 'https://raw.githubusercontent.com/Internet-Helper/GeoHideDNS/refs/heads/main/hosts/hosts'
$hostsPath = Join-Path $Repository 'openai-hosts'
$logDirectory = Join-Path $env:LOCALAPPDATA 'DnsConf'
$logPath = Join-Path $logDirectory 'openai-proxy-watch.log'
$probeHosts = @('chatgpt.com', 'auth.openai.com', 'cdn.oaistatic.com', 'files.oaiusercontent.com')

New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

function Write-Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

function Get-SourceAddress {
    $address = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $address) { throw "No IPv4 address found on $InterfaceAlias" }
    return $address
}

function Test-Proxy([string]$Address, [string]$SourceAddress) {
    foreach ($hostName in $probeHosts) {
        $client = [System.Net.Sockets.TcpClient]::new([System.Net.Sockets.AddressFamily]::InterNetwork)
        try {
            $client.Client.Bind([System.Net.IPEndPoint]::new([System.Net.IPAddress]::Parse($SourceAddress), 0))
            $connect = $client.ConnectAsync($Address, 443)
            if (-not $connect.Wait(5000) -or -not $client.Connected) { return $false }

            $stream = [System.Net.Security.SslStream]::new($client.GetStream(), $false)
            $auth = $stream.AuthenticateAsClientAsync($hostName)
            if (-not $auth.Wait(5000) -or -not $stream.IsAuthenticated) { return $false }
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
    $sourceAddress = Get-SourceAddress
    $currentAddress = (Get-Content -LiteralPath $hostsPath |
        Where-Object { $_ -match '^\s*\d{1,3}(?:\.\d{1,3}){3}\s+' } |
        Select-Object -First 1) -replace '\s+.*$', ''

    if ($currentAddress -and (Test-Proxy $currentAddress $sourceAddress)) {
        Write-Log "OK: $currentAddress"
        exit 0
    }

    Write-Log "FAILED: $currentAddress; looking for replacement"
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
        if ($candidate -ne $currentAddress -and (Test-Proxy $candidate $sourceAddress)) {
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
            "# OpenAI/ChatGPT overrides verified via physical Ethernet on $(Get-Date -Format yyyy-MM-dd)"
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

    Write-Log "UPDATED: $currentAddress -> $replacement"
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
