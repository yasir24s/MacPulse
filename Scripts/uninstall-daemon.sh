#!/bin/bash
# Remove the LaunchDaemon and its binary. Run with sudo.
set -euo pipefail
LABEL="com.yasir.macpulse"
[ "$(id -u)" = "0" ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" /usr/local/libexec/macpulsed /var/run/macpulse.sock
echo "Removed $LABEL."
