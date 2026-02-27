#!/bin/bash

# Script to install nano_pow_server as a launchd service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.nano.pow.server"
PLIST_FILE="${SCRIPT_DIR}/${PLIST_NAME}.plist"
LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
LAUNCHD_FILE="${LAUNCHD_DIR}/${PLIST_NAME}.plist"
BUILD_DIR="${SCRIPT_DIR}/build"
BINARY="${BUILD_DIR}/nano_pow_server"
LOGS_DIR="${SCRIPT_DIR}/logs"

echo "Installing nano_pow_server as a launchd service..."

# Check if binary exists
if [ ! -f "${BINARY}" ]; then
    echo "Error: Binary not found at ${BINARY}"
    echo "Please build the project first:"
    echo "  cd ${SCRIPT_DIR}"
    echo "  mkdir -p build && cd build"
    echo "  cmake .."
    echo "  make"
    exit 1
fi

# Create logs directory
mkdir -p "${LOGS_DIR}"

# Create LaunchAgents directory
mkdir -p "${LAUNCHD_DIR}"

# Get CPU thread count (use all available cores)
CPU_THREADS=$(sysctl -n hw.ncpu)

# Create config file if it doesn't exist
CONFIG_FILE="${SCRIPT_DIR}/config-nano-pow-server.toml"
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "Creating config file..."
    cat > "${CONFIG_FILE}" <<CONFIGEOF
[server]
log_to_stderr = true

[device]
type = "cpu"
threads = ${CPU_THREADS}
CONFIGEOF
    echo "Config file created at ${CONFIG_FILE}"
fi

# Generate plist file with correct paths
cat > "${LAUNCHD_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${BINARY}</string>
        <string>--config_path</string>
        <string>${CONFIG_FILE}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOGS_DIR}/nano_pow_server.out.log</string>
    <key>StandardErrorPath</key>
    <string>${LOGS_DIR}/nano_pow_server.err.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

# Unload if already loaded (try both old and new syntax for compatibility)
if launchctl list | grep -q "${PLIST_NAME}"; then
    echo "Unloading existing service..."
    launchctl bootout "gui/$(id -u)/${PLIST_NAME}" 2>/dev/null || \
    launchctl unload "${LAUNCHD_FILE}" 2>/dev/null || true
fi

# Load the service (try new syntax first, fall back to old)
echo "Loading service..."
launchctl bootstrap "gui/$(id -u)" "${LAUNCHD_FILE}" 2>/dev/null || \
launchctl load "${LAUNCHD_FILE}"

echo ""
echo "Service installed successfully!"
echo ""
echo "To check status: launchctl list | grep ${PLIST_NAME}"
echo "To view logs: tail -f ${LOGS_DIR}/nano_pow_server.err.log"
echo "To stop: launchctl bootout gui/\$(id -u)/${PLIST_NAME} || launchctl unload ${LAUNCHD_FILE}"
echo "To start: launchctl bootstrap gui/\$(id -u) ${LAUNCHD_FILE} || launchctl load ${LAUNCHD_FILE}"
