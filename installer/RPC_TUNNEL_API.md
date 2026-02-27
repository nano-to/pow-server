# rpc.nano.to Tunnel API Contract (for 10.116.0.4)

This document defines the minimum backend API required for secure one-click tunnel provisioning.

Goal: only `rpc.nano.to` should trigger `POST work_generate` through the tunnel path.

Out of scope for this API spec:

- firewall and network ACL rules
- cloud perimeter controls

Those controls are managed outside the API layer.

## Security Model

- No static/shared SSH credentials in CLI.
- CLI sends a freshly generated SSH public key to backend.
- Backend returns short-lived, worker-scoped tunnel assignment.
- Tunnel server only permits reverse forwarding for restricted user.
- No public edge exposure for tunnel ports.
- Backend must reject any method/action outside this contract.

## Required Endpoint

## `POST /api/account/work-servers/bootstrap-tunnel`

Auth: `Authorization: Bearer <work_api_key>`

Request:

```json
{
  "workerName": "macbook-m3",
  "localPort": 7077,
  "transport": "reverse-ssh",
  "sshPublicKey": "ssh-ed25519 AAAAC3...",
  "allowedMethods": ["POST"],
  "allowedActions": ["work_generate"]
}
```

Response:

```json
{
  "tunnel": {
    "enabled": true,
    "host": "142.93.62.146",
    "user": "powtunnel",
    "bindHost": "0.0.0.0",
    "remotePort": 17077,
    "sshPrivateKey": "-----BEGIN OPENSSH PRIVATE KEY-----\n...",
    "knownHost": "tunnel.nano.to ssh-ed25519 AAAAC3...",
    "expiresAt": "2026-02-27T00:00:00Z"
  },
  "policy": {
    "allowedMethods": ["POST"],
    "allowedActions": ["work_generate"],
    "maxBodyBytes": 2048
  }
}
```

Notes:

- Prefer signed SSH certs over raw private key return if available.
- `remotePort` must be unique per worker and reclaimable when offline.
- Use short lease and require periodic renewal.

## Recommended Support Endpoints

### `POST /api/account/work-servers/tunnel-heartbeat`

Updates liveness + tunnel metadata.

CLI behavior:

- heartbeat is sent only when API key exists in config
- no API key => no heartbeat calls

### `POST /api/account/work-servers/rotate-tunnel-key`

Rotates SSH material or returns fresh cert/key lease.

### `POST /api/account/work-servers/revoke-tunnel`

Immediately invalidates tunnel lease and forwarding assignment.

## RPC Enforcement

At `rpc.nano.to` caller and API boundary enforce all of:

1. Method must be `POST`
2. Path must be exact (`/` or one fixed path)
3. Content-Type must be JSON
4. Body size limit (e.g. 2KB)
5. JSON must contain only:
   - `action = work_generate`
   - `hash` 64-hex regex
6. Reject all other actions/fields and non-JSON payloads
7. Rate-limit per worker
8. Do not expose a public HTTP proxy for tunnel traffic from this API flow

## SSHD Hardening for Tunnel Host

Use dedicated tunnel user with Match block:

- `AllowTcpForwarding remote`
- `PermitTTY no`
- `X11Forwarding no`
- `AllowAgentForwarding no`
- `GatewayPorts clientspecified` (or equivalent binding control)

Global sshd should keep:

- `PermitRootLogin no`
- `PasswordAuthentication no`
- `AllowTcpForwarding no` (global)

## Data Flow (API perspective)

1. Client local worker listens on `127.0.0.1:7077`
2. SSH reverse bind on tunnel host:
   - `-R 0.0.0.0:<remotePort>:127.0.0.1:7077`
3. `rpc.nano.to` calls `http://<tunnel-host-ip-or-name>:<remotePort>`
4. `rpc.nano.to` sends only `POST` with `action=work_generate`
5. Worker returns PoW result

This keeps tunnel usage constrained to PoW generation traffic at the application/API layer.
