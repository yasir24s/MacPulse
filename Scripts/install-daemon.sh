#!/bin/bash
# Install macpulsed as a root LaunchDaemon.
#
# RUN THIS YOURSELF WITH sudo. It writes to /usr/local/libexec and
# /Library/LaunchDaemons and loads a permanently-root background process --
# a system change that should be made by a human who read the script.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/MacPulse.app"
LABEL="com.yasir.macpulse"
DEST="/usr/local/libexec/macpulsed"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

[ "$(id -u)" = "0" ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
[ -x "$APP/Contents/Helpers/macpulsed" ] || {
    echo "Build first: Scripts/bundle-app.sh" >&2; exit 1; }

echo "Stopping any running instance…"
launchctl bootout "system/$LABEL" 2>/dev/null || true

install -d -m 755 /usr/local/libexec
install -m 755 "$APP/Contents/Helpers/macpulsed" "$DEST"
install -m 644 "$ROOT/launchd/$LABEL.plist" "$PLIST"
chown root:wheel "$DEST" "$PLIST"

launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL"
sleep 2

if [ -S /var/run/macpulse.sock ]; then
    echo "Installed. Socket is live at /var/run/macpulse.sock"
else
    echo "Installed, but no socket yet — check /var/log/macpulse.err" >&2
fi
