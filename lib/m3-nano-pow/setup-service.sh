#!/bin/bash

# Setup script for Nano PoW background service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_PATH="$SCRIPT_DIR/.build/release/NanoPoW"
PLIST_NAME="com.nanopow.service.plist"
PLIST_SOURCE="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "🔧 Setting up Nano PoW Background Service"
echo ""

# Check if binary exists
if [ ! -f "$BUILD_PATH" ]; then
    echo "❌ Binary not found at $BUILD_PATH"
    echo "   Please build the project first: ./build.sh"
    exit 1
fi

echo "✅ Found binary at: $BUILD_PATH"
echo ""

# Create LaunchAgents directory if it doesn't exist
mkdir -p "$HOME/Library/LaunchAgents"

# Update plist with correct path
echo "📝 Creating service plist..."
cat > "$PLIST_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.nanopow.service</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BUILD_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/nanopow.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/nanopow.error.log</string>
    <key>WorkingDirectory</key>
    <string>$SCRIPT_DIR</string>
</dict>
</plist>
EOF

echo "✅ Service plist created at: $PLIST_DEST"
echo ""

# Unload if already loaded
if launchctl list | grep -q "com.nanopow.service"; then
    echo "🔄 Unloading existing service..."
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# Load the service
echo "📦 Loading service..."
launchctl load "$PLIST_DEST"

# Start the service
echo "🚀 Starting service..."
launchctl start com.nanopow.service

echo ""
echo "✅ Service setup complete!"
echo ""
echo "📊 Service status:"
launchctl list | grep nanopow || echo "   (Service may take a moment to appear)"
echo ""
echo "📋 View logs with:"
echo "   tail -f ~/Library/Logs/nanopow.log"
echo ""
echo "🛑 To stop the service:"
echo "   launchctl stop com.nanopow.service"
echo ""
echo "🗑️  To remove the service:"
echo "   launchctl unload ~/Library/LaunchAgents/com.nanopow.service.plist"
