#!/bin/bash
# Stop launching MacPulse at login. Leaves the daemon alone.
set -euo pipefail
LABEL="com.yasir.macpulse.app"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "Removed $LABEL. The daemon is untouched; use uninstall-daemon.sh for that."
