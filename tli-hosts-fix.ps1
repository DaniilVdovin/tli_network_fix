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
# How: for each game domain, candidate IPs = current DNS A records first,
# then the exact Cloudflare IPs (/32) from lists\ipset-torchlight.txt as
# fallback. A candidate is "working" only if the zone is actually hosted
# on that edge (HTTP 2xx/3xx/5xx/404). 403/421 means the CF edge answers
# but does NOT host the zone - pinning it would break the game, so it is
# rejected. 000 means DPI-blocked / timeout. The first working candidate
# is pinned. (Cloudflare is anycast, but only the zone-hosting edges serve
# a given domain - a random CF IP is not a valid pin.)
#
# Idempotent: only the block between the marker comments below is
# rewritten, other hosts entries are never touched.
# Run as administrator (hosts is a system file). Safe to run on every
# start - the blocked IP set changes over time, so re-probe each time.

$ErrorActionPreference = 'Stop'

# All game API domains (from the game client log, 2026-10-24).
# furt-login-torchlight.xdgtw.com is the actual login endpoint
# (/platformlogin) - it was missing from the first version and
# caused "Network request timeout" on the login screen.
$domains = @(
    'accounts.xd.com',
    'furt-login-torchlight.xdgtw.com',
    'login-xdsdk.xd.com',
    'logout-xdsdk.xd.com',
    'protocol.xd.com',
    'sdkpay.xd.com',
    'xdsdk-os-prod-gateway.xd.com',
    'xdsdk-os-prod-gateway2.xd.com',
    'version-overseas-torchlight.xdgtw.com'
)

$ipsetFile   = Join-Path $PSScriptRoot 'lists\ipset-torchlight.txt'
$hostsFile   = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$markerBegin = '# tli_network_fix begin'
$markerEnd   = '# tli_network_fix end'
$testTimeout = 5   # seconds per IP probe

# Cloudflare anycast IPv4 prefixes (used to filter ipset-torchlight.txt).
# Only exact IPs (/32) are valid pin candidates: a /24 range is not a
# single pin target, and the observed game /24 (172.65.171.0/24) does not
# host the HTTPS zone - it is the game-traffic subnet used by the winws
# desync filter in the .bat, not by this hosts fix.
$cfPrefix = '^(104\.(1[6-9]|2[0-3])\.|172\.(6[4-9]|7[0-9])\.)'
$cfIps = @()
if (Test-Path $ipsetFile) {
    $cfIps = @(Get-Content $ipsetFile |
        ForEach-Object {
            $entry = $_.Trim()
            if ($entry -eq '' -or $entry -like '#*') { return }
            $parts  = $entry -split '/'
            $prefix = if ($parts.Count -gt 1) { $parts[1] } else { '32' }
            if ($prefix -eq '32' -and $parts[0] -match $cfPrefix) { $parts[0] }
        } |
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

function Probe-Code([string]$domain, [string]$ip) {
    # returns the HTTP status code ('000' = blocked / timeout).
    # A usable pin: 2xx/3xx/5xx or 404 = the zone is actually hosted on
    # this edge. 403/421 = CF edge answers but does NOT host the zone
    # (a pin to it would break the game).
    return (& curl.exe --ssl-no-revoke --max-time $testTimeout -s -o NUL -w '%{http_code}' --resolve "${domain}:443:${ip}" "https://${domain}/" 2>$null)
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
        $code = Probe-Code $domain $ip
        if ($code -match '^((2|3|5)\d\d|404)$') { $found = $ip; break }
        Write-Host ("  {0,-40} {1,-16} {2} (not usable)" -f $domain, $ip, $code)
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

# Safety: back up the current hosts state before the first edit.
# Created once, never overwritten - the original file is preserved.
$backupFile = $hostsFile + '.bak-tli'
if (-not (Test-Path $backupFile)) {
    Copy-Item $hostsFile $backupFile -Force
    Write-Host "Backup created: $backupFile"
}

# Rewrite only our marked block, keep everything else.
# UTF-8 (no BOM): non-ASCII comments in hosts survive the rewrite.
$lines  = @(Get-Content $hostsFile -Encoding UTF8)
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

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[IO.File]::WriteAllLines($hostsFile, (@($kept) + $newBlock), $utf8NoBom)
ipconfig /flushdns | Out-Null

Write-Host ''
Write-Host '=== hosts updated ==='
$pins | ForEach-Object { Write-Host ("  {0}  {1}" -f $_.Ip, $_.Domain) }
Write-Host 'Done.'
