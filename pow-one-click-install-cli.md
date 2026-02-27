# nano-pow One-Click Install CLI

This README is a build guide for creating the `nano-pow` one-click installer and CLI flow used by the Work Servers product.

## Goal

Ship a single-command install experience:

```bash
curl -fsSL https://rpc.nano.to/install/pow.sh | bash
```

That command should:

1. Install or update `nano-pow`
2. Launch an interactive setup wizard (TUI)
3. Configure a PoW worker + reverse tunnel
4. Register/connect worker to `rpc.nano.to`
5. Start as a persistent system service

## User Experience

Expected prompts in setup:

- Work API key (required)
- Nano payout address (required)
- Bid per work (optional, default `0.00001`)
- Optional worker name/labels

Expected post-install commands:

- `nano-pow status`
- `nano-pow logs --tail 100`
- `nano-pow restart`

## Architecture

Use 3 components:

1. **Bootstrap script** (`nano-pow`)
2. **CLI binary/script** (`nano-pow`)
3. **Worker runtime + system service**

### 1) Bootstrap script (`nano-pow`)

Responsibilities:

- Detect OS/arch (Linux x64/arm64 first)
- Install dependencies (curl, tar, jq, openssh-client, autossh)
- Download latest `nano-pow` release artifact
- Verify SHA256 checksum
- Install binary to `/usr/local/bin/nano-pow`
- Run `nano-pow setup`

Minimal behavior:

- Idempotent (safe to run multiple times)
- Non-interactive dependency install where possible
- Clear colored logs and exit codes

### 2) CLI (`nano-pow`)

Recommended commands:

- `nano-pow setup` - interactive first-time configuration
- `nano-pow start` / `nano-pow stop` / `nano-pow restart`
- `nano-pow status` - worker + tunnel + API health summary
- `nano-pow logs [--tail N]`
- `nano-pow doctor` - diagnostics + common fixes
- `nano-pow uninstall`

### 3) Service layer

Create one or two systemd services:

- `nano-pow.service` - PoW worker process
- `nano-pow-tunnel.service` - autossh reverse tunnel

Both services should:

- restart on failure
- start on boot
- log to journald

## Setup Flow (Implementation Order)

1. Validate API key with backend endpoint
2. Validate payout address format
3. Write config file with root-only permissions (`600`)
4. Install service unit files
5. Enable and start services
6. Run health checks and show summary

Health checks should include:

- worker process running
- tunnel active
- `work_generate` latency check
- successful auth/registration with backend

## Backend Endpoints Needed

The CLI should rely on explicit endpoints. At minimum:

- `POST /api/account/work-servers/validate-key`
- `POST /api/account/work-servers/register-worker`
- `POST /api/account/work-servers/heartbeat`
- `POST /api/account/work-servers/test-work`

Nice-to-have:

- `GET /api/account/work-servers/installer-version`
- `POST /api/account/work-servers/diagnostics`

## Security Requirements

- Never print full API key in logs
- Store secrets only in root-owned files
- Use TLS endpoints only
- Validate hostnames and reject private/internal targets where applicable
- Verify downloaded binary checksums before install

## Release Strategy

1. Build versioned release artifacts (`nano-pow-linux-amd64`, `nano-pow-linux-arm64`)
2. Generate checksums file
3. Publish artifacts + checksums
4. Keep `nano-pow` stable and fetching latest version metadata
5. Add rollback command (`nano-pow rollback <version>`) if desired

## Suggested Repo Layout

```text
installer/
  nano-pow
  systemd/
    nano-pow.service
    nano-pow-tunnel.service
cli/
  cmd/
  internal/
  main.*
releases/
  checksums.txt
```

## MVP Checklist

- [ ] `nano-pow` downloads and installs `nano-pow`
- [ ] `nano-pow setup` prompt flow works end-to-end
- [ ] config saved to `/etc/nano-pow/config.json`
- [ ] systemd units installed and enabled
- [ ] reverse tunnel established automatically
- [ ] `nano-pow status` reports healthy state
- [ ] `nano-pow logs` and `nano-pow doctor` usable
- [ ] reinstall path is idempotent
- [ ] uninstall path removes services + binary cleanly

## Quick Test Plan

Run on a fresh Linux VM:

1. Execute installer command
2. Complete TUI prompts
3. Confirm services are active
4. Verify worker appears in account/admin UI
5. Reboot VM and confirm auto-recovery
6. Run uninstall and verify cleanup

## Copy-ready Messaging

For product/UI copy:

- "Install with one command"
- "No router port forwarding required"
- "Secure reverse tunnel to rpc.nano.to"
- "Auto-starts on reboot"
