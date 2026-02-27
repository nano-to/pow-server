#!/bin/bash

cd "$(dirname "$0")"

echo "🚀 Running Nano PoW Service..."
echo ""

# Run and capture output
.build/release/NanoPoW 2>&1 | tee test-run.log &
SERVICE_PID=$!

echo "Service started with PID: $SERVICE_PID"
echo "Waiting 30 seconds for PoW generation..."
echo ""

sleep 30

echo ""
echo "=== Stopping service ==="
kill $SERVICE_PID 2>/dev/null || pkill -f NanoPoW || true
wait $SERVICE_PID 2>/dev/null || true

echo ""
echo "=== Output ==="
cat test-run.log 2>/dev/null || echo "No output captured"
