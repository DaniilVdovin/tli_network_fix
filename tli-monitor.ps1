# TLI network monitor - netstat-based, waits for the game to start
# Log is written next to the script (tli-monitor.log)
$log = Join-Path $PSScriptRoot 'tli-monitor.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null
$sw = [System.IO.StreamWriter]::new($log, $false, [System.Text.Encoding]::UTF8)
$sw.WriteLine("=== TLI monitor start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ===")
$sw.Flush()

# Phase 1: wait for the game to start (up to 5 min)
$found = $false
for ($i = 0; $i -lt 300; $i++) {
    if (Get-Process -Name torchlight_infinite -ErrorAction SilentlyContinue) { $found = $true; break }
    Start-Sleep -Milliseconds 1000
}
if (-not $found) {
    $sw.WriteLine("$(Get-Date -Format 'HH:mm:ss.fff') [GAME NEVER STARTED]")
    $sw.Close()
    exit
}
$sw.WriteLine("$(Get-Date -Format 'HH:mm:ss.fff') [GAME STARTED]")
$sw.Flush()

# Phase 2: monitor for up to 10 minutes
for ($i = 0; $i -lt 600; $i++) {
    $ts = Get-Date -Format 'HH:mm:ss.fff'
    $procs = Get-Process -Name torchlight_infinite -ErrorAction SilentlyContinue
    if (-not $procs) {
        $sw.WriteLine("$ts [GAME EXITED]")
        break
    }
    $pids = ($procs | ForEach-Object { $_.Id }) -join '|'
    $re = "\s($pids)\s*$"
    $tcp = netstat -ano -p TCP 2>$null | Where-Object { $_ -match 'ESTABLISHED' -and $_ -match $re }
    foreach ($l in $tcp) { $sw.WriteLine("$ts TCP  " + ($l -replace '^\s+', '')) }
    $udp = netstat -ano -p UDP 2>$null | Where-Object { $_ -match $re }
    foreach ($l in $udp) { $sw.WriteLine("$ts UDP  " + ($l -replace '^\s+', '')) }
    $sw.Flush()
    Start-Sleep -Milliseconds 1000
}
$sw.WriteLine("=== TLI monitor end $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') ===")
$sw.Close()
