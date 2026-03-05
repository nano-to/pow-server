# ngrok Client-Side Internals

This document describes exactly how the `nano-pow` CLI uses ngrok to create
an HTTP tunnel from a worker machine to the public internet. The goal is to
provide enough detail to replace ngrok with a self-hosted equivalent.

---

## Overview

The worker machine runs a local HTTP server (default `127.0.0.1:7077`).
ngrok exposes that port to the internet under a stable public URL so the
backend can dispatch proof-of-work jobs to it.

```
Backend RPC  ──POST──>  <ngrok public URL>  ──>  ngrok agent  ──>  127.0.0.1:7077
```

The backend never connects to the worker machine directly. All traffic flows
through the ngrok tunnel.

---

## Bootstrap: getting credentials from the server

Before starting the tunnel the CLI calls the backend to provision per-worker
credentials:

```
POST /api/account/work-servers/bootstrap-tunnel
Authorization: Bearer <WORK_API_KEY>
Content-Type: application/json

{
  "workerName":      "<machine name>",
  "localPort":       7077,
  "transport":       "ngrok",
  "allowedActions":  ["work_generate"],
  "allowedMethods":  ["POST"]
}
```

The server holds a master `NGROK_API_KEY` and uses it to create a
per-worker ngrok credential. The response (normalized to `.tunnel.*`) contains:

| Field | Description |
|---|---|
| `tunnel.provider` | `"ngrok"` |
| `tunnel.ngrokAuthtoken` | Per-worker ngrok authtoken |
| `tunnel.ngrokCredentialId` | ngrok credential ID (echoed in heartbeats) |
| `tunnel.ngrokDomain` | Reserved domain, e.g. `foo.ngrok.app` (optional) |
| `tunnel.ngrokAllowedCidrs` | Comma-separated CIDRs for IP allowlisting (optional) |

All fields are saved to `~/.config/nano-pow/config.json` (`chmod 600`).

---

## Traffic policy file (IP allowlisting)

If `ngrokAllowedCidrs` is non-empty, the CLI writes a traffic-policy file at:

```
~/.config/nano-pow/ngrok-traffic-policy.json
```

Contents:

```json
{
  "on_http_request": [
    {
      "actions": [
        {
          "type": "restrict-ips",
          "config": {
            "enforce": true,
            "allow": ["<cidr1>", "<cidr2>"]
          }
        }
      ]
    }
  ]
}
```

File permissions: `chmod 600`. Passed to ngrok via `--traffic-policy-file`.

---

## The ngrok command

```
ngrok http \
  --authtoken=<ngrokAuthtoken> \
  --url=<ngrokDomain> \
  --traffic-policy-file=~/.config/nano-pow/ngrok-traffic-policy.json \
  127.0.0.1:<port>
```

All three optional flags (`--authtoken`, `--url`, `--traffic-policy-file`)
are omitted when the corresponding config value is absent.

---

## Process lifecycle

### macOS — launchd

Written to `~/Library/LaunchAgents/com.nano.pow.tunnel.plist`.

Key plist settings:

```xml
<key>ProgramArguments</key>
<array>
  <string>/path/to/ngrok</string>
  <string>http</string>
  <string>--authtoken=TOKEN</string>
  <string>--url=DOMAIN</string>
  <string>--traffic-policy-file=/path/to/policy.json</string>
  <string>127.0.0.1:PORT</string>
</array>
<key>KeepAlive</key><true/>
<key>RunAtLoad</key><true/>
<key>StandardOutPath</key><string>~/.local/share/nano-pow/logs/tunnel.out.log</string>
<key>StandardErrorPath</key><string>~/.local/share/nano-pow/logs/tunnel.err.log</string>
```

`KeepAlive=true` — launchd auto-restarts the process if it exits.

### Linux — systemd user unit

Written to `~/.config/systemd/user/nano-pow-tunnel.service`.

```ini
[Unit]
Description=Nano PoW ngrok Tunnel
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env ngrok http --authtoken=TOKEN --url=DOMAIN \
          --traffic-policy-file=/path/to/policy.json 127.0.0.1:PORT
Restart=always
RestartSec=2
StandardOutput=append:/path/to/tunnel.out.log
StandardError=append:/path/to/tunnel.err.log

[Install]
WantedBy=default.target
```

### Windows / foreground

```bash
nohup ngrok http --authtoken TOKEN --url DOMAIN \
  --traffic-policy-file /path/to/policy.json 127.0.0.1:PORT \
  >> tunnel.out.log 2>> tunnel.err.log &
```

PID saved to `$RUN_DIR/tunnel.pid` and used for `kill` on stop.

---

## Discovering the public URL

ngrok exposes a local REST API on `http://127.0.0.1:4040`. After starting the
process the CLI polls it until a tunnel appears (up to 20 seconds, 1-second
intervals):

```bash
curl -fsS --max-time 3 http://127.0.0.1:4040/api/tunnels
```

Response shape:

```json
{
  "tunnels": [
    {
      "public_url": "https://foo.ngrok.app",
      "proto": "https",
      ...
    }
  ]
}
```

Selection logic (in order):

1. First tunnel whose `public_url` starts with `https://`
2. Fall back to `tunnels[0].public_url`
3. If nothing is found after 20 seconds → fatal error

The discovered URL is used for:
- Registering the worker's public endpoint with the backend (via heartbeat)
- Status display in the CLI TUI

---

## Heartbeat

Every heartbeat includes the current public URL (re-discovered from the local
API on each tick) and the credential ID:

```json
{
  "workerName":        "<name>",
  "tunnelUrl":         "https://foo.ngrok.app",
  "tunnelHost":        "foo.ngrok.app",
  "tunnelPort":        "443",
  "ngrokCredentialId": "<id from bootstrap>"
}
```

The host is derived by stripping the scheme and any path from the URL.
Port is always `"443"` for ngrok HTTPS tunnels.

---

## Error handling

| Situation | Behaviour |
|---|---|
| ngrok binary not found | Auto-install via `brew install ngrok/ngrok/ngrok` (mac) or `apt`/`dnf` (linux) |
| Process exits within 2 s of start | Log tail printed, fatal error |
| Public URL not found after 20 s | Log tail printed, fatal error |
| HTTP response body contains `ERR_NGROK_XXXX` | Parsed into `"ngrok endpoint offline (ERR_NGROK_XXXX)"` and surfaced in status TUI |

---

## Special HTTP header

Requests sent through the tunnel include:

```
ngrok-skip-browser-warning: true
```

This bypasses ngrok's browser interstitial page on free-tier tunnels.

A self-hosted replacement does not need this header.

---

## What to replicate in a self-hosted tunnel

To replace ngrok client-side the replacement must:

1. **Start a process** that forwards `<public-host>:<public-port>` → `127.0.0.1:<local-port>` over HTTP.
2. **Expose a local REST API** (or equivalent) so the CLI can discover the current public URL without restarting.
   - Endpoint: `GET http://127.0.0.1:<api-port>/api/tunnels`
   - Response: `{ "tunnels": [{ "public_url": "https://..." }] }`
3. **Support a reserved/stable domain** equivalent to `--url` so the URL does not change across restarts.
4. **Support IP allowlisting** equivalent to `--traffic-policy-file` (the `restrict-ips` action).
5. **Be manageable by launchd / systemd** with auto-restart on crash.
6. **Not require a browser interstitial** (ngrok shows one on free plans; the CLI skips it with a header).
7. **Issue per-worker credentials server-side** and accept them as a startup flag equivalent to `--authtoken`.
