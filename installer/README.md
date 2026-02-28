# NANO.TO PoW Installer + Tunnel Test Guide

Use this guide to test PoW locally first, then verify a private reverse tunnel consumed only by your RPC backend.

## Quick Local Test (No Config, No API Key)

Run the local worker with the TUI:

```bash
./installer/nano-pow --local --port 7077
```

In the TUI:

- `t` runs a local PoW probe
- `q` quits
- add `--debug` if you want log panes

From another terminal, verify local PoW:

```bash
curl -sS -X POST "http://127.0.0.1:7077" -H "Content-Type: application/json" --data '{"action":"work_generate","hash":"E89208DD038FBB269987689621D52292FE9B863A173550C797762D7329D0E0F7"}'
```

## One-Click Managed Setup

If your backend implements the bootstrap endpoint, users can run:

```bash
curl -fsSL https://raw.githubusercontent.com/nano-to/pow-server/main/installer/pow.sh | WORK_API_KEY="<work_api_key>" bash
```

This auto-provisions tunnel settings from your backend, starts worker + tunnel, and avoids manual SSH details.

## Reverse Tunnel Test (RPC-Only, Private)

Assumptions:

- Your worker runs locally at `127.0.0.1:7077`
- SSH access exists to tunnel host (example: `142.93.62.146`)
- `autossh` is installed locally

Start tunnel from your local machine:

```bash
autossh -M 0 -N \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -o StrictHostKeyChecking=accept-new \
  -i ~/.ssh/id_ed25519 \
  -R 0.0.0.0:17077:127.0.0.1:7077 \
  powtunnel@142.93.62.146
```

On tunnel host, firewall must only allow `10.116.0.4 -> 17000:17999` and deny public sources.
Now from your backend host, test the tunnel target directly:

```bash
curl -sS -X POST "http://142.93.62.146:17077" -H "Content-Type: application/json" --data '{"action":"work_generate","hash":"E89208DD038FBB269987689621D52292FE9B863A173550C797762D7329D0E0F7"}'
```

If this works, the reverse tunnel is good.

No public endpoint should proxy this traffic.

## Included Files

- `installer/nano-pow`: main CLI and local TUI
- `installer/pow.sh`: curl-pipe bootstrap installer
