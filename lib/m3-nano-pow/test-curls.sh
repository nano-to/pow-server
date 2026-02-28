#!/bin/bash
set -euo pipefail
LOCAL_URL="http://127.0.0.1:8070"
RPC_URL="${RPC_URL:-https://rpc.example.com}"

HASHES=(
  "E89208DD038FBB269987689621D52292FE9B863A173550C797762D7329D0E0F7"
  "9F3D8B0B4E0B1B4E9E9A2D7F9B8C0F2C2B6E7F1A3C4D5E6F7A8B9C0D1E2F3A4B"
  "A5B7C9D1E3F507192B3D4F5A6B7C8D9E0F1A2B3C4D5E6F708192A3B4C5D6E7F8"
  "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"
  "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
)

for i in {1..5}; do
  HASH=${HASHES[$((i-1))]}
  echo "--- request $i ---"
  echo "hash: $HASH"
  WORK_JSON=$(curl -s -d "{\"action\":\"work_generate\",\"hash\":\"$HASH\"}" -H "Content-Type: application/json" "$LOCAL_URL")
  echo "local: $WORK_JSON"
  WORK=$(python3 - <<PY
import json
try:
  data=json.loads('''$WORK_JSON''')
  print(data.get('work',''))
except Exception:
  print('')
PY
)
  if [ -z "$WORK" ]; then
    echo "no work returned"
    echo
    continue
  fi
  VALIDATE_JSON=$(curl -s "$RPC_URL" -H "Content-Type: application/json" -d "{\"action\":\"work_validate\",\"hash\":\"$HASH\",\"work\":\"$WORK\"}")
  echo "validate: $VALIDATE_JSON"
  echo
  sleep 0.3
done
