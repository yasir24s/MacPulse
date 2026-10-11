#!/bin/bash
# Install macpulsed as a root LaunchDaemon.
#
# Writes to /usr/local/libexec and /Library/LaunchDaemons and loads a
# permanently-root background process, so it needs an administrator. Run it
# plainly and macOS asks for the password in its standard dialog; `sudo` from
# a terminal still works the same way it always did.
#
# Runs from two places, and finds its inputs relative to itself:
#   repo:   Scripts/install-daemon.sh  -> build/MacPulse.app + launchd/
#   bundle: MacPulse.app/Contents/Resources/install-daemon.sh -> ../Helpers
# The bundle copy is what the app's "Update daemon..." button runs, so the
# daemon installed is always the one built alongside that exact app.
#
# ASCII only and every expansion braced: macOS /bin/bash is 3.2, and under a
# UTF-8 locale a multibyte character after an unbraced $VAR is read as part
# of the name, which trips set -u.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DIR}/$(basename "${BASH_SOURCE[0]}")"

if [ -x "${DIR}/../Helpers/macpulsed" ]; then
    HELPER_SRC="${DIR}/../Helpers/macpulsed"
    PLIST_SRC="${DIR}/com.yasir.macpulse.plist"
else
    ROOT="$(cd "${DIR}/.." && pwd)"
    HELPER_SRC="${ROOT}/build/MacPulse.app/Contents/Helpers/macpulsed"
    PLIST_SRC="${ROOT}/launchd/com.yasir.macpulse.plist"
fi

LABEL="com.yasir.macpulse"
DEST="/usr/local/libexec/macpulsed"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

[ -x "${HELPER_SRC}" ] || { echo "No daemon binary at ${HELPER_SRC}. Build first: Scripts/bundle-app.sh" >&2; exit 1; }
[ -f "${PLIST_SRC}" ]  || { echo "No LaunchDaemon plist at ${PLIST_SRC}" >&2; exit 1; }

# A downloaded release carries com.apple.quarantine on every file, and
# install(1) copies that tag onto the destination, so the root daemon would
# land in /usr/local/libexec quarantined. Stop and say how to clear it rather
# than stripping the tag here: removing a security attribute is the owner's
# call, and it is made once for the whole app. Checked before the password
# prompt, so nobody types a password for an install that cannot work.
if xattr -p com.apple.quarantine "${HELPER_SRC}" >/dev/null 2>&1; then
    APP_BUNDLE="$(cd "$(dirname "${HELPER_SRC}")/../.." && pwd)"
    echo "This copy of MacPulse is quarantined (downloaded, and not notarized), so the" >&2
    echo "daemon would be installed quarantined too. Clear it once, then install again:" >&2
    echo "  xattr -dr com.apple.quarantine '${APP_BUNDLE}'" >&2
    exit 1
fi

if [ "$(id -u)" != "0" ]; then
    # Re-run this same file as root via the standard macOS password dialog.
    # The path travels as an argv item, never spliced into AppleScript
    # source, so no quoting of it can break or be abused.
    # 'without altering line endings': by default do shell script turns every
    # newline into a carriage return, so each line overprints the last and
    # only the final one stays visible -- warnings included.
    exec /usr/bin/osascript \
        -e 'on run argv' \
        -e 'do shell script (quoted form of (item 1 of argv)) with administrator privileges without altering line endings' \
        -e 'end run' \
        "${SCRIPT}"
fi

echo "Stopping any running instance..."
launchctl bootout "system/${LABEL}" 2>/dev/null || true

# bootout returns before launchd has finished unregistering the service, and
# bootstrapping into that half-removed state fails with "5: Input/output
# error". Wait for it to actually go away rather than racing it.
for _ in $(seq 1 25); do
    launchctl print "system/${LABEL}" >/dev/null 2>&1 || break
    sleep 0.2
done
# A wedged daemon can outlive bootout (one blocked 17 h in a socket write and
# had to be killed by hand). Make sure nothing is holding the socket.
pkill -9 -x macpulsed 2>/dev/null || true
rm -f /var/run/macpulse.sock

install -d -m 755 /usr/local/libexec
install -m 755 "${HELPER_SRC}" "${DEST}"
install -m 644 "${PLIST_SRC}" "${PLIST}"
chown root:wheel "${DEST}" "${PLIST}"

if ! launchctl bootstrap system "${PLIST}"; then
    echo "bootstrap failed; retrying once after a longer settle..." >&2
    sleep 2
    launchctl bootstrap system "${PLIST}"
fi
launchctl enable "system/${LABEL}"
sleep 2

if [ -S /var/run/macpulse.sock ]; then
    echo "Installed. Socket is live at /var/run/macpulse.sock"
else
    echo "Installed, but no socket yet -- check /var/log/macpulse.err" >&2
    exit 1
fi
