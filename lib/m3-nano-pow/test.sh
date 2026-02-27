#!/bin/bash

# Test script to run Nano PoW service and capture output

cd "$(dirname "$0")"

echo "🧪 Testing Nano PoW Service..."
echo ""

# Run the service in background and capture output
.build/release/NanoPoW > test_output.log 2>&1 &
SERVICE_PID=$!

echo "⏳ Service started (PID: $SERVICE_PID)"
echo "📋 Waiting for PoW generation and validation..."
echo ""

# Wait a bit for output
sleep 15

# Show the output
echo "📄 Service Output:"
echo "=================="
cat test_output.log
echo ""

# Kill the service
kill $SERVICE_PID 2>/dev/null || true
wait $SERVICE_PID 2>/dev/null || true

echo ""
echo "✅ Test complete"
