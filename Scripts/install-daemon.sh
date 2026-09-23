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

# bootout returns before launchd has finished unregistering the service, and
# bootstrapping into that half-removed state fails with "5: Input/output
# error". Wait for it to actually go away rather than racing it.
for _ in $(seq 1 25); do
    launchctl print "system/$LABEL" >/dev/null 2>&1 || break
    sleep 0.2
done
# A wedged daemon can outlive bootout (one blocked 17 h in a socket write and
# had to be killed by hand). Make sure nothing is holding the socket.
pkill -9 -x macpulsed 2>/dev/null || true
rm -f /var/run/macpulse.sock

install -d -m 755 /usr/local/libexec
install -m 755 "$APP/Contents/Helpers/macpulsed" "$DEST"
install -m 644 "$ROOT/launchd/$LABEL.plist" "$PLIST"
chown root:wheel "$DEST" "$PLIST"

if ! launchctl bootstrap system "$PLIST"; then
    echo "bootstrap failed; retrying once after a longer settle…" >&2
    sleep 2
    launchctl bootstrap system "$PLIST"
fi
launchctl enable "system/$LABEL"
sleep 2

if [ -S /var/run/macpulse.sock ]; then
    echo "Installed. Socket is live at /var/run/macpulse.sock"
else
    echo "Installed, but no socket yet — check /var/log/macpulse.err" >&2
fi
