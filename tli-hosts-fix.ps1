# tli-hosts-fix.ps1
#
# Auto-pin working Cloudflare IPs for Torchlight Infinite domains in the
# Windows hosts file.
#
# Why: DPI blocks specific Cloudflare anycast IPs (pure IP-based block,
# not SNI-based). The game's domains each resolve to a PAIR of Cloudflare
# IPs, so login / version check fails whenever the client picks the
# blocked one. Desync cannot change the destination IP, so the working
# IP is pinned in hosts.
#
# How: for each game domain, candidate IPs = current DNS A records +
# Cloudflare IPs from lists\ipset-torchlight.txt (fallback when DNS is
# empty or poisoned; Cloudflare is anycast, so any working 104.18.x.x /
# 172.64.x.x serves every domain by SNI). Every candidate is probed with
# curl; the first one that answers is pinned.
#
# Idempotent: only the block between the marker comments below is
# rewritten, other hosts entries are never touched.
# Run as administrator (hosts is a system file). Safe to run on every
# start - the blocked IP set changes over time, so re-probe each time.

$ErrorActionPreference = 'Stop'

$domains = @(
    'accounts.xd.com',
    'xdsdk-os-prod-gateway.xd.com',
    'xdsdk-os-prod-gateway2.xd.com',
    'version-overseas-torchlight.xdgtw.com'
)

$ipsetFile   = Join-Path $PSScriptRoot 'lists\ipset-torchlight.txt'
$hostsFile   = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$markerBegin = '# tli_network_fix begin'
$markerEnd   = '# tli_network_fix end'
$testTimeout = 5   # seconds per IP probe

# Cloudflare anycast IPv4 prefixes (used to filter ipset-torchlight.txt)
$cfPrefix = '^(104\.(1[6-9]|2[0-3])\.|172\.(6[4-9]|7[0-9])\.)'
$cfIps = @()
if (Test-Path $ipsetFile) {
    $cfIps = @(Get-Content $ipsetFile |
        ForEach-Object { ($_ -split '/')[0] } |
        Where-Object { $_ -match $cfPrefix } |
        Select-Object -Unique)
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DomainIps([string]$domain) {
    $ips = @()
    try {
        $ips += [System.Net.Dns]::GetHostAddresses($domain) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.IPAddressToString }
    } catch { }
    if (-not $ips) {
        # fallback: parse nslookup (same system resolver / DNS server)
        $out = & nslookup $domain 2>&1 | Out-String
        $server = ''
        if ($out -match '(?m)^Address:\s+([\d.]+)') { $server = $Matches[1] }
        $ips += [regex]::Matches($out, '\b\d{1,3}(?:\.\d{1,3}){3}\b') |
            ForEach-Object { $_.Value } |
            Where-Object { $_ -ne $server }
    }
    return @($ips | Select-Object -Unique)
}

function Test-Ip([string]$domain, [string]$ip) {
    # any real HTTP status (100-599) means TCP+TLS to the IP worked;
    # 000 means blocked / timeout
    $code = & curl.exe --ssl-no-revoke --max-time $testTimeout -s -o NUL -w '%{http_code}' --resolve "${domain}:443:${ip}" "https://${domain}/" 2>$null
    return ($code -match '^[1-5]\d\d$')
}

Write-Host ''
Write-Host '=== tli-hosts-fix: probing Cloudflare IPs ==='

$pins = @()
foreach ($domain in $domains) {
    $dnsIps = @(Get-DomainIps $domain)
    $candidates = @($dnsIps) + @($cfIps | Where-Object { $dnsIps -notcontains $_ })
    $candidates = @($candidates | Select-Object -Unique)

    $found = $null
    foreach ($ip in $candidates) {
        if (Test-Ip $domain $ip) { $found = $ip; break }
        Write-Host ("  {0,-40} {1,-16} blocked" -f $domain, $ip)
    }

    if ($found) {
        $pins += [pscustomobject]@{ Domain = $domain; Ip = $found }
        Write-Host ("  {0,-40} {1,-16} OK" -f $domain, $found)
    } else {
        Write-Host ("  {0,-40} NO WORKING IP FOUND (manual re-diagnosis needed)" -f $domain)
    }
}

if (-not $pins) {
    Write-Host ''
    Write-Host 'No working IPs found - hosts not modified.'
    exit 1
}

if (-not (Test-IsAdmin)) {
    Write-Host ''
    Write-Host 'NOT ADMINISTRATOR - cannot write hosts. Pins to add manually:'
    $pins | ForEach-Object { Write-Host ("  {0}  {1}" -f $_.Ip, $_.Domain) }
    exit 1
}

# Rewrite only our marked block, keep everything else.
$lines  = @(Get-Content $hostsFile)
$inBlock = $false
$kept = foreach ($line in $lines) {
    $t = $line.Trim()
    if ($t -eq $markerBegin) { $inBlock = $true;  continue }
    if ($t -eq $markerEnd)   { $inBlock = $false; continue }
    if (-not $inBlock) { $line }
}
$newBlock = @($markerBegin) +
    @($pins | ForEach-Object { '{0}  {1}' -f $_.Ip, $_.Domain }) +
    @($markerEnd, '')

Set-Content -Path $hostsFile -Value (@($kept) + $newBlock) -Encoding ascii
ipconfig /flushdns | Out-Null

Write-Host ''
Write-Host '=== hosts updated ==='
$pins | ForEach-Object { Write-Host ("  {0}  {1}" -f $_.Ip, $_.Domain) }
Write-Host 'Done.'
