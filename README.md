# Torchlight Infinite — DPI network fix

Login / version-check failures in Torchlight Infinite (TLI),
and the zapret profile that fixes them.

## Symptoms

- Login to the first menu: timeout (in-game error 1027)
- Before login: `Network connection failed, do you want to reconnect? Version Server Response :: 0 35`
- Before login: `Network connection failed, do you want to reconnect? Version Server Response :: 0 56`

## Root cause (two independent DPI blocks)

1. **Session channel block.** The game session runs over TCP port 1005
   (Alibaba IPs, e.g. `172.65.171.245`). DPI kills the channel after ~15–25 s.
   Fix: zapret game filter `1005-65535` (TCP+UDP) + desync for game IPs
   (`lists/ipset-torchlight.txt`).

2. **Cloudflare IP block.** DPI blocks specific Cloudflare anycast IPs
   (observed 2026-10-24: `104.18.29.95`, `104.18.24.187`; the set changes over time).
   The block is IP-based: any SNI times out to a blocked IP, other Cloudflare
   IPs work. Login/version domains each resolve to a *pair* of Cloudflare IPs —
   if the client hits the blocked one first, version check or login fails:

   | Domain | Purpose |
   |---|---|
   | `furt-login-torchlight.xdgtw.com` | login (`/platformlogin`) |
   | `accounts.xd.com` | account / login |
   | `login-xdsdk.xd.com`, `logout-xdsdk.xd.com` | SDK login / logout |
   | `xdsdk-os-prod-gateway.xd.com`, `xdsdk-os-prod-gateway2.xd.com` | SDK / auth gateway |
   | `sdkpay.xd.com` | payments |
   | `protocol.xd.com` | protocol |
   | `version-overseas-torchlight.xdgtw.com` | version check |

   Desync cannot fix this (it cannot change the destination IP).
   Workaround: pin the working IPs in `C:\Windows\System32\drivers\etc\hosts`.
   The Cloudflare IPs are also listed in `lists/ipset-torchlight.txt`, so the
   profile desyncs traffic to them (harmless for a pure IP block, useful if
   DPI ever blocks these domains by SNI).

## Contents

- `general (Torchlight).bat` — zapret profile, run as administrator.
  Before starting zapret it runs `tli-hosts-fix.ps1` (see below)
- `tli-hosts-fix.ps1` — probes the game's Cloudflare IPs and pins the
  working ones in `C:\Windows\System32\drivers\etc\hosts` (only its own
  marked block, other entries are never touched). Runs on every start
  because the blocked IP set changes over time
- `update-zapret.bat` — copies the fix files into the zapret folder,
  if it is next to this one (`..\zapret-discord-youtube`)
- `lists/ipset-torchlight.txt` — game server IPs + Cloudflare anycast IPs of
  the game's login/version domains (update when the game moves to new servers
  or the Cloudflare pair rotates). The other list files
  (`list-general.txt`, `ipset-all.txt`, ...) are part of the zapret repo
  itself — the bat expects them in your zapret folder.
- `tli-monitor.ps1` — network monitor: waits for the game to start, logs all
  its TCP/UDP connections every second for 10 minutes to `tli-monitor.log`
  (next to the script)

## Setup

1. Put the fix files into your zapret (zapret-discord-youtube) folder:
   run `update-zapret.bat` if the zapret folder is next to this one,
   otherwise copy `general (Torchlight).bat`, `tli-hosts-fix.ps1` and
   `lists/ipset-torchlight.txt` manually.
2. Run `general (Torchlight).bat` as administrator. The bat first probes
   every Cloudflare IP of the game's domains and pins the working ones
   in hosts (a few seconds, re-tested on every start).
3. If the script prints `NO WORKING IP FOUND` for a domain, pin working
   IPs manually in `hosts` (as admin) and restart the game:

   ```
   104.18.28.95 accounts.xd.com
   104.18.25.187 furt-login-torchlight.xdgtw.com
   104.18.28.95 login-xdsdk.xd.com
   104.18.28.95 xdsdk-os-prod-gateway.xd.com
   104.18.28.95 xdsdk-os-prod-gateway2.xd.com
   104.18.25.187 version-overseas-torchlight.xdgtw.com
   ```

   IPs verified 2026-10-24. When the pins stop working, re-resolve the
   domains and re-test the IPs (procedure below).

## Re-diagnosis (when it breaks again)

1. Start the game, log its connections every second: run `tli-monitor.ps1`
   (waits for the game to start, 10 minutes, writes `tli-monitor.log`).
2. `ipconfig /displaydns` — find the game's domains (`*.xd.com`, `*.xdgtw.com`).
3. Test every resolved IP:

   ```
   curl --ssl-no-revoke --max-time 6 -o NUL -w "%{http_code}" --resolve <domain>:443:<ip> https://<domain>/
   ```

   - `000` / timeout → blocked IP
   - `200` / `404` → working IP

4. Update `lists/ipset-torchlight.txt` (new game IPs / Cloudflare pair) and
   the hosts pins (working Cloudflare IPs).

## Observed game endpoints (2026-10-24)

| Endpoint | Notes |
|---|---|
| `172.65.171.245:1005` | session channel (Alibaba) |
| `8.222.163.102:19100` | game server (Alibaba) |
| `161.117.125.0/24` :80/:443 | game services |
| `43.109.31.237`, `43.109.31.240` | game services (Alibaba) |
| `47.88.128.3:80` | game services |
| `47.241.35.211` | TapTap SDK |
| Cloudflare `104.18.x.x` / `172.64.x.x` | login / version / CDN (`xd.com`, `xdgtw.com`) |
