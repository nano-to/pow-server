#!/bin/bash

# Build script for M3 Nano PoW Service

echo "🔨 Building Nano PoW Service for M3 MacBook..."
echo ""

# Clean previous build
echo "🧹 Cleaning previous build..."
swift package clean

# Build in release mode
echo "📦 Building release version..."
swift build -c release

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Build successful!"
    echo "📍 Binary location: .build/release/NanoPoW"
    echo ""
    echo "To run the service:"
    echo "  .build/release/NanoPoW"
    echo ""
    echo "To set up as background service:"
    echo "  1. Update com.nanopow.service.plist with correct path"
    echo "  2. Copy to ~/Library/LaunchAgents/"
    echo "  3. Run: launchctl load ~/Library/LaunchAgents/com.nanopow.service.plist"
else
    echo ""
    echo "❌ Build failed!"
    exit 1
fi
