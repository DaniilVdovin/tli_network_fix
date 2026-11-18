# tli-scan.ps1
#
# Diagnostic scan: find which IPs currently serve the Torchlight game
# domains. Read-only - does NOT touch hosts.
#
# Phases:
#   1. DNS A records per game domain + curl probe (per domain).
#   2. Full sweep of 172.65.171.0/24 (observed game subnet) against one
#      representative domain - Cloudflare is anycast, an unblocked IP
#      serves every domain by SNI.
#   3. Cloudflare IPs harvested from popular CF-hosted domains, probed
#      against the representative domain (blocked set is IP-based, so
#      any live CF anycast IP is a candidate).
#
# Output: working IPs per domain + suggested pin list.
#
# -SkipDns: skip phases 1/1b (DNS + per-domain probes), run only the
# anycast sweeps (phases 2-3).

param([switch]$SkipDns)

$ErrorActionPreference = 'Continue'

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

$probeDomain = 'accounts.xd.com'
$timeout     = 4   # seconds per probe

function Get-DomainIps([string]$domain) {
    $ips = @()
    try {
        $ips += [System.Net.Dns]::GetHostAddresses($domain) |
            Where-Object { $_.AddressFamily -eq 'InterNetwork' } |
            ForEach-Object { $_.IPAddressToString }
    } catch { }
    if (-not $ips) {
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
    # returns the HTTP status code string ('000' = blocked/timeout)
    return (& curl.exe --ssl-no-revoke --max-time $timeout -s -o NUL -w '%{http_code}' --resolve "${domain}:443:${ip}" "https://${domain}/" 2>$null)
}

function Test-CodeIsHosted([string]$code) {
    # 2xx/3xx/5xx or 404 = the zone is actually hosted on this edge.
    # 403/421 = CF edge answers but does NOT host the zone (useless pin).
    # 000 = blocked / timeout.
    return ($code -match '^(2\d\d|3\d\d|5\d\d|404)$')
}

function Invoke-ParallelProbe([string]$domain, [string[]]$ips, [int]$workers = 24) {
    # Parallel curl probes via Process handles (no PSThreadJob needed).
    $results = @{}
    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($ip in $ips) { $pending.Enqueue($ip) }
    $running = @{}   # ip -> Process
    while (($pending.Count -gt 0) -or ($running.Count -gt 0)) {
        # fill up to $workers running probes
        while ($running.Count -lt $workers -and $pending.Count -gt 0) {
            $ip = $pending.Dequeue()
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'curl.exe'
            $psi.Arguments = "--ssl-no-revoke --max-time $timeout -s -o NUL -w ""%{http_code}"" --resolve `"${domain}:443:${ip}`" ""https://${domain}/"""
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $running[$ip] = [System.Diagnostics.Process]::Start($psi)
        }
        # wait for any to finish
        $finished = @()
        foreach ($ip in @($running.Keys)) {
            if ($running[$ip].HasExited) { $finished += $ip }
        }
        if ($finished.Count -eq 0) { Start-Sleep -Milliseconds 100; continue }
        foreach ($ip in $finished) {
            $p = $running[$ip]
            $code = ''
            try {
                $p.WaitForExit() | Out-Null
                $code = $p.StandardOutput.ReadToEnd().Trim()
                $p.StandardError.ReadToEnd() | Out-Null
            } catch { }
            $results[$ip] = $code
            $p.Dispose()
            $running.Remove($ip) | Out-Null
        }
    }
    return $results
}

$dnsMap = @{}
$dnsResults = @()
if (-not $SkipDns) {
    Write-Host '=== Phase 1: DNS A records per domain ==='
    foreach ($d in $domains) {
        $ips = @(Get-DomainIps $d)
        $dnsMap[$d] = $ips
        $ipStr = if ($ips) { $ips -join ', ' } else { '(none)' }
        Write-Host ("  {0,-42} {1}" -f $d, $ipStr)
    }

    Write-Host ''
    Write-Host '=== Phase 1b: probing DNS IPs per domain ==='
    foreach ($d in $domains) {
        foreach ($ip in $dnsMap[$d]) {
            $code = Test-Ip $d $ip
            $ok = Test-CodeIsHosted $code
            $dnsResults += [pscustomobject]@{ Domain = $d; Ip = $ip; Source = 'dns'; Ok = $ok }
            Write-Host ("  {0,-42} {1,-18} {2,-6} {3}" -f $d, $ip, $code, $(if ($ok) { 'OK' } else { 'not-hosted/blocked' }))
        }
    }
    Write-Host ''
}

Write-Host ''
Write-Host ("=== Phase 2: sweep 172.65.171.0/24 vs {0} ===" -f $probeDomain)
$sweepIps = @()
for ($i = 1; $i -le 254; $i++) { $sweepIps += "172.65.171.$i" }
$sweep = Invoke-ParallelProbe $probeDomain $sweepIps 24
$liveSubnet = @($sweep.GetEnumerator() | Where-Object { Test-CodeIsHosted $_.Value } | ForEach-Object Name)
$codeDist = $sweep.Values | Group-Object | Sort-Object Count -Descending | ForEach-Object { "{0}={1}" -f $_.Name, $_.Count }
Write-Host ("  status codes: {0}" -f ($codeDist -join ' '))
Write-Host ("  hosted IPs in subnet: {0}" -f $(if ($liveSubnet) { $liveSubnet -join ', ' } else { 'none' }))

Write-Host ''
Write-Host ("=== Phase 3: CF IPs from popular domains vs {0} ===" -f $probeDomain)
# Popular Cloudflare-fronted domains. Any live CF anycast IP is a
# candidate for the game domains (block is IP-based, not SNI-based).
$cfSources = @(
    'cloudflare.com', 'discord.com', 'discord.gg', 'reddit.com',
    'netflix.com', 'twitch.tv', 'spotify.com', 'openai.com',
    'anthropic.com', 'sentry.io', 'stripe.com', 'slack.com',
    'notion.so', 'vercel.com', 'netlify.com', 'cloudinary.com',
    'whatsapp.com', 'telegram.org', 'medium.com', 'figma.com'
)
$cfIps = @()
foreach ($s in $cfSources) {
    $ips = @(Get-DomainIps $s)
    foreach ($ip in $ips) {
        if ($ip -match '^(104\.(1[6-9]|2[0-3])\.|172\.(6[4-9]|7[0-9])\.)') { $cfIps += $ip }
    }
}
# drop IPs already covered by the game DNS (probed in phase 1b)
$knownDns = @($dnsMap.Values | Where-Object { $_ } | ForEach-Object { @($_) })
$cfIps = @($cfIps | Where-Object { $knownDns -notcontains $_ } | Select-Object -Unique)
Write-Host ("  harvested CF IPs: {0}" -f $cfIps.Count)
if ($cfIps) {
    $cf = Invoke-ParallelProbe $probeDomain $cfIps 24
    $liveCf = @($cf.GetEnumerator() | Where-Object { Test-CodeIsHosted $_.Value } | ForEach-Object Name)
    $cfDist = $cf.Values | Group-Object | Sort-Object Count -Descending | ForEach-Object { "{0}={1}" -f $_.Name, $_.Count }
    Write-Host ("  status codes: {0}" -f ($cfDist -join ' '))
    Write-Host ("  hosted CF IPs: {0}" -f $(if ($liveCf) { $liveCf -join ', ' } else { 'none' }))
} else {
    $liveCf = @()
}

Write-Host ''
Write-Host '=== Summary ==='
$allLive = @($liveSubnet) + @($liveCf)
$allLive = @($allLive | Select-Object -Unique)
Write-Host ("  live non-DNS IPs (serve any domain by SNI): {0}" -f $(if ($allLive) { $allLive -join ', ' } else { 'none' }))
Write-Host ''
Write-Host '  Suggested pins (per domain):'
foreach ($d in $domains) {
    $dnsOk = @($dnsResults | Where-Object { $_.Domain -eq $d -and $_.Ok })
    if ($dnsOk) {
        Write-Host ("    {0}  {1}   [dns]" -f $dnsOk[0].Ip, $d)
    } elseif ($allLive) {
        Write-Host ("    {0}  {1}   [anycast-sweep]" -f $allLive[0], $d)
    } else {
        Write-Host ("    {0}  {1}   [NO WORKING IP]" -f '-', $d)
    }
}
