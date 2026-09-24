#!/bin/bash
# Remove the macpulsed LaunchDaemon and its binary.
#
# Needs an administrator. Run it plainly and macOS asks for the password in
# its standard dialog; `sudo` from a terminal still works the same way.
#
# ASCII only and every expansion braced: macOS /bin/bash is 3.2, and under a
# UTF-8 locale a multibyte character after an unbraced $VAR is read as part
# of the name, which trips set -u.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DIR}/$(basename "${BASH_SOURCE[0]}")"
LABEL="com.yasir.macpulse"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
BINARY="/usr/local/libexec/macpulsed"
SOCKET="/var/run/macpulse.sock"

if [ "$(id -u)" != "0" ]; then
    # Re-run this same file as root via the standard macOS password dialog.
    # The path travels as an argv item, never spliced into AppleScript source.
    # 'without altering line endings': otherwise do shell script turns every
    # newline into a carriage return and each line overprints the last.
    exec /usr/bin/osascript \
        -e 'on run argv' \
        -e 'do shell script (quoted form of (item 1 of argv)) with administrator privileges without altering line endings' \
        -e 'end run' \
        "${SCRIPT}"
fi

echo "Stopping ${LABEL}..."
launchctl bootout "system/${LABEL}" 2>/dev/null || true

# bootout is asynchronous. Wait for the daemon to actually exit: its SIGTERM
# handler is what hands the fan back to the firmware curve, and deleting
# things out from under it before then gains nothing.
for _ in $(seq 1 25); do
    launchctl print "system/${LABEL}" >/dev/null 2>&1 || pgrep -x macpulsed >/dev/null || break
    sleep 0.2
done
if pgrep -x macpulsed >/dev/null; then
    # A wedged daemon can outlive bootout. SIGKILL cannot be caught, so the
    # fan failsafe will NOT run for it -- say so rather than hide it.
    pkill -9 -x macpulsed 2>/dev/null || true
    echo "Warning: macpulsed did not exit cleanly and was killed; if it was driving" >&2
    echo "the fan, the fan may still be at its last forced speed." >&2
fi

rm -f "${PLIST}" "${BINARY}" "${SOCKET}"

if launchctl print "system/${LABEL}" >/dev/null 2>&1 || [ -e "${PLIST}" ] || [ -e "${BINARY}" ] || pgrep -x macpulsed >/dev/null; then
    echo "Something is still present -- check manually." >&2
    exit 1
fi
echo "Removed ${LABEL}."
