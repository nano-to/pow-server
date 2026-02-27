#!/usr/bin/env bash
#
# test-ngrok-e2e.sh — End-to-end ngrok tunnel test for nano-pow worker
#
# Full pipeline:
#   1. Start the RPC backend server locally (with NGROK_AUTHTOKEN)
#   2. Start a mock PoW worker on LOCAL_PORT (default 7077)
#   3. Call bootstrap-tunnel on the local RPC server to get ngrok authtoken
#   4. Start ngrok tunnel pointing to mock worker
#   5. Discover ngrok public URL via local API
#   6. Send work_generate through the ngrok tunnel
#   7. Send heartbeat to local RPC server
#   8. Teardown all processes
#
# Usage:
#   WORK_API_KEY=<key> NGROK_AUTHTOKEN=<token> ./test-ngrok-e2e.sh
#
# Environment:
#   WORK_API_KEY       - Required. Account work API key for bootstrap-tunnel auth.
#   NGROK_AUTHTOKEN    - Required. Master ngrok authtoken (server distributes to CLI).
#   RPC_SERVER_PORT    - Local RPC server port (default: 7999)
#   LOCAL_PORT         - Mock PoW worker port (default: 7077)
#   SKIP_SERVER        - If "1", skip starting local RPC server (use RPC_API_BASE)
#   RPC_API_BASE       - Backend URL (default: http://localhost:$RPC_SERVER_PORT)
#

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RPC_SERVER_PORT="${RPC_SERVER_PORT:-7999}"
LOCAL_PORT="${LOCAL_PORT:-7077}"
NGROK_API="http://127.0.0.1:4040/api/tunnels"
WORKER_NAME="e2e-test-$(date +%s)"
TEST_HASH="E89208DD038FBB269987689621D52292FE9B863A173550C797762D7329D0E0F7"
SKIP_SERVER="${SKIP_SERVER:-0}"

if [[ "$SKIP_SERVER" == "1" ]]; then
  RPC_API_BASE="${RPC_API_BASE:-https://rpc.nano.to}"
else
  RPC_API_BASE="${RPC_API_BASE:-http://localhost:${RPC_SERVER_PORT}}"
fi

# Colors
RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"
BOLD="\033[1m"; RESET="\033[0m"

# PIDs for cleanup
WORKER_PID=""
NGROK_PID=""
SERVER_PID=""

PASS_COUNT=0
FAIL_COUNT=0

# ── Helpers ──────────────────────────────────────────────────────────────────

log_info() { printf "%b[INFO]%b %s\n" "$CYAN" "$RESET" "$*"; }
log_ok()   { printf "%b[ OK ]%b %s\n" "$GREEN" "$RESET" "$*"; }
log_warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$*"; }
log_err()  { printf "%b[FAIL]%b %s\n" "$RED" "$RESET" "$*" >&2; }
die()      { log_err "$*"; cleanup; exit 1; }

pass() { PASS_COUNT=$((PASS_COUNT + 1)); log_ok "$*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); log_err "$*"; }

cleanup() {
  log_info "Cleaning up..."
  if [[ -n "$NGROK_PID" ]] && kill -0 "$NGROK_PID" 2>/dev/null; then
    kill "$NGROK_PID" 2>/dev/null || true
    wait "$NGROK_PID" 2>/dev/null || true
    log_info "Stopped ngrok (pid $NGROK_PID)"
  fi
  if [[ -n "$WORKER_PID" ]] && kill -0 "$WORKER_PID" 2>/dev/null; then
    kill "$WORKER_PID" 2>/dev/null || true
    wait "$WORKER_PID" 2>/dev/null || true
    log_info "Stopped mock worker (pid $WORKER_PID)"
  fi
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    log_info "Stopped RPC server (pid $SERVER_PID)"
  fi
}
trap cleanup EXIT INT TERM

# ── Pre-flight checks ───────────────────────────────────────────────────────

printf "\n%b══════════════════════════════════════════════════════════%b\n" "$BOLD$CYAN" "$RESET"
printf "%b  ngrok Tunnel End-to-End Test%b\n" "$BOLD" "$RESET"
printf "%b══════════════════════════════════════════════════════════%b\n\n" "$BOLD$CYAN" "$RESET"

# Check required tools
for cmd in curl jq ngrok node; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Missing required command: $cmd"
  fi
done
log_ok "All required tools available (curl, jq, ngrok, node)"

# Check env vars
if [[ -z "${WORK_API_KEY:-}" ]]; then
  die "WORK_API_KEY environment variable is required"
fi
log_ok "WORK_API_KEY is set"

if [[ -z "${NGROK_AUTHTOKEN:-}" && "$SKIP_SERVER" != "1" ]]; then
  die "NGROK_AUTHTOKEN environment variable is required (the server passes it to CLI clients)"
fi
log_ok "NGROK_AUTHTOKEN is set"

# Kill any existing processes on the ports we need
for port_to_check in "$LOCAL_PORT" "4040"; do
  if lsof -i ":$port_to_check" -t >/dev/null 2>&1; then
    log_warn "Port $port_to_check is in use. Freeing it..."
    kill $(lsof -i ":$port_to_check" -t) 2>/dev/null || true
    sleep 1
  fi
done

if [[ "$SKIP_SERVER" != "1" ]]; then
  if lsof -i ":$RPC_SERVER_PORT" -t >/dev/null 2>&1; then
    log_warn "Port $RPC_SERVER_PORT is in use. Freeing it..."
    kill $(lsof -i ":$RPC_SERVER_PORT" -t) 2>/dev/null || true
    sleep 1
  fi
fi

# ── Step 0: Start local RPC server (optional) ───────────────────────────────

if [[ "$SKIP_SERVER" != "1" ]]; then
  log_info "Step 0: Starting local RPC server on port $RPC_SERVER_PORT"

  # Load .env.local variables for DB connection
  if [[ -f "$PROJECT_ROOT/.env.local" ]]; then
    set -a
    source "$PROJECT_ROOT/.env.local"
    set +a
    log_ok "Loaded .env.local (DB: $PGHOST:$PGPORT/$PGDATABASE)"
  else
    log_warn "No .env.local found, server may fail to connect to database"
  fi

  # Export NGROK_AUTHTOKEN for the server process
  export NGROK_AUTHTOKEN

  node "$PROJECT_ROOT/index.js" "$RPC_SERVER_PORT" > /tmp/rpc-server-e2e.log 2>&1 &
  SERVER_PID=$!

  # Wait for the server to become ready
  server_ready=false
  for i in $(seq 1 40); do
    if curl -sS --max-time 2 -X POST "http://localhost:${RPC_SERVER_PORT}" \
       -H "Content-Type: application/json" \
       --data '{"action":"version"}' >/dev/null 2>&1; then
      server_ready=true
      break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      log_err "RPC server crashed. Last 30 lines of log:"
      tail -30 /tmp/rpc-server-e2e.log 2>/dev/null || true
      die "RPC server exited before becoming ready"
    fi
    if (( i % 10 == 0 )); then
      log_info "  Waiting for RPC server... (attempt $i/40)"
    fi
    sleep 0.5
  done

  if [[ "$server_ready" != "true" ]]; then
    log_err "RPC server log (last 30 lines):"
    tail -30 /tmp/rpc-server-e2e.log 2>/dev/null || true
    die "RPC server failed to start within 20 seconds"
  fi

  pass "RPC server running on port $RPC_SERVER_PORT (pid $SERVER_PID)"
fi

# ── Step 1: Start mock PoW worker ────────────────────────────────────────────

log_info "Step 1: Starting mock PoW worker on port $LOCAL_PORT"

node -e "
const http = require('http');
const crypto = require('crypto');

const server = http.createServer((req, res) => {
  if (req.method === 'GET') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: 'nano-pow-mock-worker', port: ${LOCAL_PORT} }));
    return;
  }

  if (req.method !== 'POST') {
    res.writeHead(405, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Method not allowed' }));
    return;
  }

  let body = '';
  req.on('data', c => body += c);
  req.on('end', () => {
    try {
      const payload = JSON.parse(body);
      const action = payload.action || 'unknown';

      if (action === 'work_generate') {
        const work = crypto.randomBytes(8).toString('hex');
        const result = {
          work: work,
          difficulty: 'fffffff800000000',
          multiplier: '1.0',
          hash: payload.hash || '0000000000000000000000000000000000000000000000000000000000000000'
        };
        console.log('[worker] work_generate -> ' + work);
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } else {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Unsupported action: ' + action }));
      }
    } catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid JSON' }));
    }
  });
});

server.listen(${LOCAL_PORT}, '127.0.0.1', () => {
  console.log('[worker] Mock PoW worker listening on 127.0.0.1:${LOCAL_PORT}');
});
" &
WORKER_PID=$!
sleep 1

if ! kill -0 "$WORKER_PID" 2>/dev/null; then
  die "Mock worker failed to start"
fi

local_response=$(curl -sS --max-time 5 -X POST "http://127.0.0.1:${LOCAL_PORT}" \
  -H "Content-Type: application/json" \
  --data "{\"action\":\"work_generate\",\"hash\":\"${TEST_HASH}\"}" 2>/dev/null || echo "")

local_work=$(echo "$local_response" | jq -r '.work // empty' 2>/dev/null || echo "")
if [[ -z "$local_work" ]]; then
  die "Mock worker returned invalid response: $local_response"
fi
pass "Mock worker running and responding (work=$local_work)"

# ── Step 2: Bootstrap tunnel from backend ────────────────────────────────────

log_info "Step 2: Calling bootstrap-tunnel on $RPC_API_BASE"

bootstrap_response=$(curl -sS --max-time 15 \
  -X POST "${RPC_API_BASE}/api/account/work-servers/bootstrap-tunnel" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WORK_API_KEY}" \
  --data "{\"workerName\":\"${WORKER_NAME}\",\"localPort\":${LOCAL_PORT},\"transport\":\"ngrok\",\"allowedActions\":[\"work_generate\"],\"allowedMethods\":[\"POST\"]}" 2>/dev/null || echo "")

if [[ -z "$bootstrap_response" ]]; then
  die "No response from bootstrap-tunnel endpoint"
fi

# Normalize response (handle nested .response.data, .data, or direct)
normalized=$(echo "$bootstrap_response" | jq -c '
  if (.response and .response.data) then .response.data
  elif .data then .data
  else .
  end
' 2>/dev/null || echo "{}")

# Check for errors
bootstrap_error=$(echo "$bootstrap_response" | jq -r '
  if .error then (.error | tostring)
  elif .message then .message
  else empty
  end
' 2>/dev/null || echo "")
if [[ -n "$bootstrap_error" && "$bootstrap_error" != "null" ]]; then
  die "Bootstrap-tunnel returned error: $bootstrap_error (Full: $bootstrap_response)"
fi

# Extract fields
ngrok_authtoken_from_api=$(echo "$normalized" | jq -r '.tunnel.ngrokAuthtoken // empty' 2>/dev/null || echo "")
tunnel_provider=$(echo "$normalized" | jq -r '.tunnel.provider // empty' 2>/dev/null || echo "")
ngrok_credential_id=$(echo "$normalized" | jq -r '.tunnel.ngrokCredentialId // empty' 2>/dev/null || echo "")
ngrok_domain=$(echo "$normalized" | jq -r '.tunnel.ngrokDomain // empty' 2>/dev/null || echo "")

if [[ "$tunnel_provider" != "ngrok" ]]; then
  die "Expected tunnel provider 'ngrok', got: '$tunnel_provider'. Response: $bootstrap_response"
fi

if [[ -z "$ngrok_authtoken_from_api" || "$ngrok_authtoken_from_api" == "null" ]]; then
  die "No ngrok authtoken in bootstrap response. Is NGROK_API_KEY set on the server? Response: $bootstrap_response"
fi

masked_token="${ngrok_authtoken_from_api:0:8}...${ngrok_authtoken_from_api: -4}"
pass "Bootstrap-tunnel returned ngrok authtoken ($masked_token)"
pass "Tunnel provider: $tunnel_provider"

# Verify per-worker credential was created (not the shared master token)
if [[ -n "$ngrok_credential_id" && "$ngrok_credential_id" != "null" ]]; then
  pass "Per-worker ngrok credential created: $ngrok_credential_id"
else
  log_warn "No per-worker credential ID returned (using shared authtoken fallback)"
fi

# ── Step 3: Start ngrok (using authtoken from API) ──────────────────────────

log_info "Step 3: Starting ngrok tunnel to 127.0.0.1:$LOCAL_PORT"

if [[ -n "$ngrok_domain" && "$ngrok_domain" != "null" ]]; then
  ngrok http --authtoken="$ngrok_authtoken_from_api" --url "$ngrok_domain" "127.0.0.1:${LOCAL_PORT}" --log=stdout --log-format=logfmt > /tmp/ngrok-e2e-test.log 2>&1 &
else
  ngrok http --authtoken="$ngrok_authtoken_from_api" "127.0.0.1:${LOCAL_PORT}" --log=stdout --log-format=logfmt > /tmp/ngrok-e2e-test.log 2>&1 &
fi
NGROK_PID=$!
sleep 2

if ! kill -0 "$NGROK_PID" 2>/dev/null; then
  log_err "ngrok failed to start. Log output:"
  tail -20 /tmp/ngrok-e2e-test.log 2>/dev/null || true
  die "ngrok process exited immediately"
fi

# ── Step 4: Discover ngrok public URL ────────────────────────────────────────

log_info "Step 4: Discovering ngrok public URL via local API"

ngrok_url=""
for i in $(seq 1 20); do
  api_response=$(curl -fsS --max-time 3 "$NGROK_API" 2>/dev/null || echo "")
  if [[ -n "$api_response" ]]; then
    ngrok_url=$(echo "$api_response" | jq -r '
      (.tunnels // [] | map(select((.public_url // "") | startswith("https://"))) | .[0].public_url) // empty
    ' 2>/dev/null || echo "")
    if [[ -z "$ngrok_url" ]]; then
      ngrok_url=$(echo "$api_response" | jq -r '(.tunnels // [])[0].public_url // empty' 2>/dev/null || echo "")
    fi
  fi
  if [[ -n "$ngrok_url" && "$ngrok_url" != "null" ]]; then
    break
  fi
  if (( i % 5 == 0 )); then
    log_info "  Waiting for ngrok tunnel... (attempt $i/20)"
  fi
  sleep 1
done

if [[ -z "$ngrok_url" || "$ngrok_url" == "null" ]]; then
  log_err "ngrok log:"
  tail -20 /tmp/ngrok-e2e-test.log 2>/dev/null || true
  die "Could not discover ngrok public URL after 20 seconds"
fi

pass "ngrok tunnel established: $ngrok_url"

# ── Step 5: End-to-end work_generate through tunnel ─────────────────────────

log_info "Step 5: Sending work_generate through ngrok tunnel"

tunnel_response=$(curl -sS --max-time 15 \
  -X POST "$ngrok_url" \
  -H "Content-Type: application/json" \
  -H "ngrok-skip-browser-warning: true" \
  --data "{\"action\":\"work_generate\",\"hash\":\"${TEST_HASH}\"}" 2>/dev/null || echo "")

if [[ -z "$tunnel_response" ]]; then
  fail "No response from ngrok tunnel URL"
else
  tunnel_work=$(echo "$tunnel_response" | jq -r '.work // empty' 2>/dev/null || echo "")
  tunnel_hash=$(echo "$tunnel_response" | jq -r '.hash // empty' 2>/dev/null || echo "")
  tunnel_difficulty=$(echo "$tunnel_response" | jq -r '.difficulty // empty' 2>/dev/null || echo "")

  if [[ -z "$tunnel_work" ]]; then
    fail "work_generate through tunnel did not return work. Response: $tunnel_response"
  else
    pass "work_generate #1 through tunnel: work=$tunnel_work hash=$tunnel_hash difficulty=$tunnel_difficulty"
  fi
fi

# ── Step 6: Heartbeat ────────────────────────────────────────────────────────

log_info "Step 6: Sending heartbeat to backend"

ngrok_host="${ngrok_url#*://}"
ngrok_host="${ngrok_host%%/*}"
ngrok_host="${ngrok_host%%:*}"

heartbeat_response=$(curl -sS --max-time 10 \
  -X POST "${RPC_API_BASE}/api/account/work-servers/heartbeat" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${WORK_API_KEY}" \
  --data "{\"workerName\":\"${WORKER_NAME}\",\"localPort\":${LOCAL_PORT},\"tunnelHost\":\"${ngrok_host}\",\"tunnelPort\":\"443\",\"tunnelUrl\":\"${ngrok_url}\",\"version\":\"0.1.0-e2e-test\",\"ngrokCredentialId\":\"${ngrok_credential_id}\"}" 2>/dev/null || echo "")

hb_error=""
if [[ -n "$heartbeat_response" ]]; then
  hb_error=$(echo "$heartbeat_response" | jq -r '
    if .error then (.error | tostring)
    elif .message then .message
    else empty
    end
  ' 2>/dev/null || echo "")
  if [[ -n "$hb_error" && "$hb_error" != "null" ]]; then
    log_warn "Heartbeat returned: $hb_error (non-blocking)"
  else
    pass "Heartbeat sent successfully"
  fi
else
  log_warn "Heartbeat got no response (non-blocking)"
fi

# ── Step 7: Second round-trip ────────────────────────────────────────────────

log_info "Step 7: Second work_generate for stability"

second_hash="0000000000000000000000000000000000000000000000000000000000000001"
second_response=$(curl -sS --max-time 15 \
  -X POST "$ngrok_url" \
  -H "Content-Type: application/json" \
  -H "ngrok-skip-browser-warning: true" \
  --data "{\"action\":\"work_generate\",\"hash\":\"${second_hash}\"}" 2>/dev/null || echo "")

second_work=$(echo "$second_response" | jq -r '.work // empty' 2>/dev/null || echo "")
if [[ -n "$second_work" ]]; then
  pass "work_generate #2 through tunnel: work=$second_work"
else
  fail "Second work_generate failed. Response: $second_response"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

printf "\n%b══════════════════════════════════════════════════════════%b\n" "$BOLD$CYAN" "$RESET"
printf "%b  END-TO-END TEST RESULTS%b\n" "$BOLD" "$RESET"
printf "%b══════════════════════════════════════════════════════════%b\n\n" "$BOLD$CYAN" "$RESET"

printf "  Passed: %b%d%b\n" "$GREEN" "$PASS_COUNT" "$RESET"
printf "  Failed: %b%d%b\n" "$RED" "$FAIL_COUNT" "$RESET"
printf "  ngrok:  %s\n\n" "$ngrok_url"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf "%b  SOME TESTS FAILED%b\n\n" "$BOLD$RED" "$RESET"
  cleanup
  exit 1
fi

printf "%b  ALL TESTS PASSED%b\n\n" "$BOLD$GREEN" "$RESET"

# Cleanup happens via trap
exit 0
