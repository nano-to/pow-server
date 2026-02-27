#!/bin/bash

# Script to uninstall nano_pow_server launchd service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_NAME="com.nano.pow.server"
LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
LAUNCHD_FILE="${LAUNCHD_DIR}/${PLIST_NAME}.plist"

echo "Uninstalling nano_pow_server launchd service..."

# Unload the service if it's running (try both old and new syntax)
if launchctl list | grep -q "${PLIST_NAME}"; then
    echo "Unloading service..."
    launchctl bootout "gui/$(id -u)/${PLIST_NAME}" 2>/dev/null || \
    launchctl unload "${LAUNCHD_FILE}" 2>/dev/null || true
fi

# Remove the plist file
if [ -f "${LAUNCHD_FILE}" ]; then
    echo "Removing plist file..."
    rm "${LAUNCHD_FILE}"
fi

echo "Service uninstalled successfully!"
