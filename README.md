# Nano PoW Server

Production-focused Nano proof-of-work server and one-click tunnel CLI.

This repository contains:

- `nano_pow_server` (standalone PoW service, C++)
- `installer/nano-pow` (operator CLI for install/setup/status)
- `installer/pow.sh` (one-line bootstrap installer)
- optional local admin UI in `public/`

## Why This Exists

Running reliable PoW capacity in production usually means solving two problems at once:

1. Fast and stable work generation
2. Safe connectivity from private workers to your backend

This project provides both:

- battle-tested PoW server APIs (`work_generate`, `work_validate`, queue/control endpoints)
- a one-click CLI that can provision local services and a managed tunnel flow

## Quick Start

### Option A: One-line installer

```bash
curl -fsSL https://raw.githubusercontent.com/nano-to/pow-server/main/installer/pow.sh | bash
```

If you already have a Work API key:

```bash
curl -fsSL https://raw.githubusercontent.com/nano-to/pow-server/main/installer/pow.sh | WORK_API_KEY="<work_api_key>" bash
```

### Option B: Build from source

```bash
git clone --recursive https://github.com/nano-to/pow-server.git
cd pow-server
cmake -S . -B build -DNANO_POW_STANDALONE=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release -j
```

Run the server:

```bash
./build/nano_pow_server --config server.log_to_stderr=true
```

Health check:

```bash
curl -sS http://127.0.0.1:8076/api/v1/ping
```

## CLI Workflow

Main commands:

```bash
nano-pow one-click
nano-pow setup
nano-pow start
nano-pow stop
nano-pow restart
nano-pow status --watch
nano-pow logs --tail 100
nano-pow doctor
nano-pow uninstall
```

By default, the CLI reads/writes config under:

- `~/.config/nano-pow/`
- `~/.local/state/nano-pow/`

## API Overview

The PoW server supports REST and WebSocket workflows.

Core endpoint:

- `POST /api/v1/work`

Actions:

- `work_generate`
- `work_validate`
- `work_cancel`

Operational endpoints:

- `GET /api/v1/ping`
- `GET /api/v1/version`
- `GET /api/v1/work/queue`
- `DELETE /api/v1/work/queue` (requires control enabled)
- `GET /api/v1/stop` (requires control enabled)

## Security Posture

- never commit real API keys, SSH private keys, or tunnel credentials
- run workers on private networks where possible
- expose public access only through controlled reverse proxy/tunnel layers
- enforce method/action allowlists on any backend tunnel ingress
- treat installer/bootstrap channels as production artifacts (version, checksum, review)

## Repository Notes

- legacy dependencies are vendored in `deps/`
- generated runtime logs and local state are intentionally git-ignored
- installer docs and tunnel contract are in `installer/`

## License

MIT (see `LICENSE`)
