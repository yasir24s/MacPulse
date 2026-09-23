#!/bin/bash
# Launch the MacPulse menu bar app at login.
#
# A user LaunchAgent, not a System Settings login item: it lives in the repo,
# survives being reinstalled, and can be removed by deleting one file. No sudo
# -- this only touches the user's own LaunchAgents directory.
#
# The DAEMON does not need this. /Library/LaunchDaemons/com.yasir.macpulse.plist
# already has RunAtLoad, so collection starts at boot before any login.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="com.yasir.macpulse.app"
SRC="$ROOT/launchd/$LABEL.plist"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$ROOT/build/MacPulse.app/Contents/MacOS/MacPulse"

[ "$(id -u)" != "0" ] || { echo "Do NOT run this with sudo -- it installs a *user* agent." >&2; exit 1; }
[ -x "$APP" ] || { echo "Build first: Scripts/bundle-app.sh release" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents"
# Rewrite the binary path so a clone in another location still works.
sed "s|<string>/Users/[^<]*/MacPulse/build/MacPulse.app/Contents/MacOS/MacPulse</string>|<string>$APP</string>|" \
    "$SRC" > "$DEST"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in $(seq 1 15); do
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
    sleep 0.2
done
launchctl bootstrap "gui/$(id -u)" "$DEST"
launchctl enable "gui/$(id -u)/$LABEL"

echo "Installed $DEST"
echo "MacPulse will now start at login. Remove with Scripts/uninstall-login-item.sh"
