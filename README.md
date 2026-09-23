# MacPulse

Live telemetry for the Mac itself — a root LaunchDaemon that samples the SoC,
memory, swap, storage and power once a second, and a menu bar app that draws
the last few minutes of it.

Not a diagnostic tool. [Auscult](../Auscult) answers *"is this device healthy?"*
about iOS devices and returns verdicts. MacPulse answers *"what is this Mac
doing right now, and what was it doing a minute ago?"* and returns only
readings. Keeping those apart is deliberate — a verdict-shaped MacPulse would
just be a worse Auscult pointed at the wrong machine.

## Build

```bash
Scripts/generate-icons.sh      # needs rsvg-convert (brew install librsvg)
Scripts/bundle-app.sh release  # -> build/MacPulse.app
```

No `.xcodeproj`, so no DerivedData. The whole bundle is ~1.2 MB.

## Install the daemon

The collector needs root because `powermetrics` does. Read the script first —
it writes to `/usr/local/libexec` and `/Library/LaunchDaemons` and loads a
permanently-root background process.

```bash
sudo Scripts/install-daemon.sh
open build/MacPulse.app
```

To remove it: `sudo Scripts/uninstall-daemon.sh`

## Architecture

```
powermetrics (root) ─┐
Mach / IOKit / sysctl ├─> macpulsed ──unix socket──> MacPulse.app (user)
                      │   ring buffer               menu bar panel
                      │   6 h @ 1 Hz
```

- **Unix socket, not TCP.** The daemon is root. A loopback TCP port is
  reachable by every process on the machine; filesystem permissions on
  `/var/run/macpulse.sock` are real access control. The protocol is
  one-directional — the app never writes back.
- **Native APIs, not subprocesses.** `host_statistics64`, `IOBlockStorageDriver`,
  `IOPowerSources` and `sysctlbyname` instead of shelling out to `vm_stat` and
  `iostat`. At 1 Hz forever, two forks a tick is ~170k processes a day on a
  machine that is already memory-starved; the monitor would become part of what
  it measures. `ps` is the one exception, sampled every 5th tick.
- **One `ps`, two orderings.** The process table is forked once every five
  ticks and sorted twice in-process, giving both a CPU-ordered and a
  memory-ordered list for the cost of the fork that was already being paid.
- **The daemon restarts powermetrics itself.** A frozen chart looks exactly
  like an idle machine, which is the most misleading failure this tool could
  have. launchd's `KeepAlive` is the backstop for the daemon itself.

## What it shows, and why in that order

Swap first, then memory, then **who is holding it**, then storage — on an 8 GB
Apple Silicon laptop those are almost always the binding constraint, and
CPU/thermals almost never are. The memory-ordered process list sits directly
under the memory card because "what is eating it" is the immediate next
question, and the CPU-ordered list very rarely answers it.

The number worth understanding is **thrash ratio** (swapins ÷ swapouts).
Swap *being used* is normal and expected here. Swap where ins ≈ outs means
pages are evicted and immediately faulted back — that is thrash, and it is a
different condition entirely. `swapouts throttled` climbing means the volume
is too full to absorb the writes, which is the upstream cause of the former.

## Temperature

Real die temperature, via `IOHIDEventSystem` — services matching AppleVendor
usage page `0xFF00`, usage `5`. Reads 60.3 °C where CleanMyMac reads 136 °F,
so the two agree.

This took a correction worth recording. `powermetrics` dropped its `smc`
sampler on Apple Silicon, and it is tempting to conclude from that alone that
die temperature is unobtainable — this README said exactly that in its first
version. It is wrong. Classic four-char SMC keys (`TC0P`, `Tp01`) really do
return nothing on an M-series die, but the sensors simply moved to IOHID.

The symbols are private, so every one is resolved with `dlsym` at
construction and `Thermal()` returns nil if any is missing. An OS that moves
them costs one card, not a crash — capability, not version checking.

### What this Mac actually exposes

Mac14,7 names **no** CPU, GPU, SOC or ANE sensor. It reports `PMU tdie1..8`
(the SoC die), `PMU2 tdie1..8`, `PMU tdev*`, `NAND CH0 temp`, and six
`gas gauge battery` cells — 38 in total. The panel shows `max(PMU tdie*)` as
the headline and lists the rest under their real hardware names. Mapping
`tdie3` onto a "GPU temperature" label would be fabrication, so it does not.

Two readings are excluded deliberately: `PMU tcal` is a calibration reference
rather than a measured temperature, and unpopulated sensors report small
negatives (`tdev4` sits at −1.7 °C), so anything at or below 1 °C is dropped.

## Fans

Fan speed is the one thing on this machine still living where it lived on
Intel: `FNum` for the count, then `F0Ac` / `F0Mn` / `F0Mx` per fan, read from
`AppleSMC` via `IOConnectCallStructMethod`. Temperatures moved to IOHID on
Apple Silicon (see above); fans did not. The value type did change — `fpe2`
fixed-point on Intel, IEEE `flt` here — so the decoder switches on the type
the SMC reports for the key rather than assuming either.

The parameter block is built as raw bytes at explicit C offsets, not as a
Swift struct. The equivalent Swift struct lays out at 76 bytes where C pads it
to 80, which shifts every field past `key` and makes **every** key report
absent — indistinguishable from a Mac with no fan. `#KEY` (the SMC's own key
count, 1756 here) is the cheap way to tell a layout bug from a fanless Mac:
if that reads, the block is right.

RPM is shown against the SMC's own floor and ceiling rather than raw, because
a bare figure means nothing across machines — 7,200 rpm is flat out on this
Mac and unremarkable on a Mac Pro. Fanless Macs report an empty list, never a
zero: on a fan gauge zero means *stopped*, which is a specific and alarming
claim rather than "unknown".

## Free space: two right answers

`statvfs` reports 24.8 GB free. Finder and CleanMyMac report 41.4 GB. Both are
correct — the latter is `volumeAvailableCapacityForImportantUsage`, which
counts ~16.6 GB of purgeable space (snapshots, evictable caches) as available.

MacPulse leads with the `statvfs` figure and shows purgeable as a separate
row, because the swapper cannot count on reclaim: the `swapouts throttled`
events on this machine happened *while* that purgeable space nominally
existed. A dashboard showing only 41.4 GB would have reported plenty of room
at the exact moment there was none.

## Alerts

Threshold rules live in `Sources/MacPulseApp/Alerts.swift` and are evaluated on
every tick rather than when the panel opens — an alert you only get while
already looking at the monitor is not an alert. Each rule carries a *separate*
clear predicate rather than the negation of its fire predicate, so a value
resting exactly on the threshold cannot chatter, and notifications are limited
to one per five minutes per rule.

A rule may also set `sustainFor`, which holds it un-reported until its
condition has held *continuously* for that long. Most conditions worth
watching here are normal in bursts: the fan hits maximum during any long
compile, and that is the cooling system working rather than a fault. `fan-max`
uses 120 s; `swapout-throttled` and `disk-floor` use zero, because both are
already unambiguous the instant they appear.

Current rules: `swapout-throttled` (critical, on the counter *climbing*, not
its value), `disk-floor` (critical, under 10 GB, clears above 15), `thermal`
(warning, Heavy or worse, clears only at Nominal), `fan-max` (warning, at 95%
of the fan's own range for two minutes, clears at 75%), and `thrash` below.

Rules are readings, not verdicts: they name which number crossed which line.

### Calibrating the thrash rule

`thrashRatio` on its own cannot carry an alert. It is `min(in/out, 2.0)` and
defined as zero whenever `out` is zero, so across 605 samples of this
machine's own history it read 0.00 at the 99th percentile and cleared 0.5 in
exactly **one tick**. It also reads a perfect 1.0 on two swapins against two
swapouts, which is an idle machine. The absolute-rate gate is what gives it
meaning.

The rule therefore fires on `swapOut >= 100 pages/s` (~1.6 MB/s) **and**
`ratio >= 0.7`, sustained 30 s. Evicting 100 pages and faulting 70 straight
back is already thrash; waiting for parity would miss most of it. The 2.0 cap
means "faulting back more than we evict" also clears the bar, which is correct.

30 s comes from the data: the longest consecutive run above any candidate
threshold in that history was **one second**, a thirtyfold margin. Replaying
all 605 real samples fires zero times — no false positives on observed idle
behaviour. Clearing is wide on both axes (rate under 50, *or* ratio under 0.3)
so a machine oscillating around the fire line cannot reopen it.

### What an induced episode changed

The thresholds above survived a deliberate memory-pressure test; the *engine*
did not. Cycling a 3 GB working set for 75 s produced a genuine 25-second
thrash episode — swapouts peaking at 31,774 pages/s, free memory down to 9%,
ratio swinging between 0.36 and the 2.0 cap.

Real thrash is **bursty**. The kernel writes swap in batches, so individual
seconds inside a sustained episode show `swapOut` at exactly zero. Under the
original engine — which retired an alert the moment `clear` held for one tick
— those zero-seconds reset the ripening clock. 23 of 88 ticks matched the fire
predicate, but the longest unbroken run was **8 s against a 30 s gate**, so the
rule would have sat silent through the entire episode. Every synthetic test
passed, because synthetic thrash is smooth.

The fix is `clearFor`, the mirror of `sustainFor`: the clear predicate must
hold *continuously* before an alert retires, and a gap no longer resets
ripening. `thrash` uses 20 s. Replaying the captured episode through the real
engine now reports on 46 ticks, first at index 30 — exactly the gate — and
retires when the machine recovers, while the 605 idle samples still fire zero
times.

Both recordings are kept as fixtures; `AlertEngine` takes an injectable clock
so they replay at full speed instead of in real time.

## Network counters are 32-bit, whatever the header says

`if_data64.ifi_ibytes` is declared 64-bit and Swift imports it that way, but
the `RTM_IFINFO2` message only ever populates the low 32 bits — confirmed by
scanning all 180 bytes of en0's message for netstat's 39.7 GB figure and
finding it at no offset at all. (The message is 180 bytes; Swift's imported
`if_msghdr2` is 160, so the header is stale against this kernel too.)

That is harmless here *provided the arithmetic respects it*. Truncation is
reduction mod 2^32, and both addition and subtraction survive it, so the
wrapped difference of the wrapped sums is the exact delta as long as under
4 GiB moved between samples — 34 Gb/s at 1 Hz, which this machine cannot
reach. What breaks is widening the counters to 64-bit before subtracting:
that turns a single interface's wrap into a 4-billion-byte spike. Verified
against `netstat -ib` under load, agreeing to 0.14%.

Loopback is excluded. lo0 carries every local IPC round-trip on the machine,
including this daemon's own socket, and including it would swamp the only
question the card answers.

## Version skew

The app and daemon share `Sample`, and a daemon older than the app sends
frames the app cannot decode. That used to present as a connected socket that
never produced a sample — indistinguishable from a wedged collector. The panel
now names it and tells you to reinstall. Always run `Scripts/install-daemon.sh`
after `bundle-app.sh` when `Sample` has changed.

## Reclaiming snapshot space

The Storage card can thin APFS local snapshots. It does **not** go through the
daemon. `macpulsed` runs as root with a one-directional socket; adding a
command channel would mean any process running as you could trigger root
deletions with no password, turning a `sudo`-gated act into an unauthenticated
one. Instead the unprivileged app calls
`do shell script … with administrator privileges`, so macOS raises its real
authentication panel on **every** invocation and nothing gains standing
privilege.

`SMAppService` was the obvious-looking choice and is the wrong one here. It
authenticates once at *registration* and then leaves a permanently-root helper
— the same standing-privilege model this avoids — and it validates a code
requirement against a Developer ID this machine does not have.

Two safeguards, because this deletes things:

- **Two-step.** The button reveals what will happen before the auth panel
  appears, and `Copy command` is offered beside it so the action can be run by
  hand instead.
- **Staged-update warning.** A `com.apple.os.update-MSUPrepareUpdate` snapshot
  is a prepared macOS update's rollback point. On this machine all three
  snapshots are update-related, so "reclaiming" 16.6 GB means deleting update
  state on a seed build. The card says so rather than presenting a clean number.

It uses `tmutil thinlocalsnapshots <vol> <bytes> 4`, which thins *toward* a
target and lets the OS keep what it still needs, rather than blanket-deleting.

## Fan control

MacPulse can drive the fan, not just watch it. Three modes per fan: **Auto**
(the SMC's own curve — MacPulse writes nothing), **Manual** (one speed), and
**Curve** (target interpolated from die temperature).

The mechanism is two SMC keys: `F<i>Md` selects firmware (0) or forced (1)
control, and `F<i>Tg` carries the target. Reading them is unprivileged;
writing needs root, which the daemon already has. Nothing else is required —
this is exactly what Macs Fan Control does, and `F0Md = 1` is how you can see
it is running.

### Why the failsafe is the feature

The dangerous state is not "wrong speed". It is **forced to a low speed with
nothing left supervising it** — the daemon dies, `F0Md` stays 1, and the
machine cooks under a firmware curve that is no longer in control. So `auto`
is the resting state and every failure path unwinds to it:

- **Thermal failsafe.** Die at or above 90 °C releases the fan to firmware
  regardless of policy, and only re-engages below 80 °C. The gap is
  hysteresis; without it a machine sitting on the threshold would hand the
  fan back and forth every second.
- **Blind curve.** Curve mode with no die temperature reverts to firmware. A
  curve without its input is not a curve, and a stale target is worse than
  no target.
- **Hardware clamp.** Targets are clamped to the fan's own reported
  `F<i>Mn`/`F<i>Mx`, not to constants, so no policy can command a speed the
  hardware does not support.
- **Exit paths.** `atexit` plus SIGTERM/SIGINT/SIGHUP/SIGQUIT all release the
  fan. SIGKILL cannot be caught, which is precisely why the thermal failsafe
  above must be able to save the machine without any of this running.
- **Default is auto.** Installing changes nothing until a mode is chosen.

Targets are only written when they move by more than 25 rpm, so a curve does
not generate a pointless SMC write every second.

### Another tool will fight you

Two controllers writing `F0Md`/`F0Tg` means last-writer-wins, and both will
keep re-asserting. The daemon detects this — in Auto, if the fan still reports
forced, the panel names the likely culprit (Macs Fan Control, TG Pro, iStat
Menus) instead of silently overwriting it. **Quit the other tool before using
Manual or Curve**; setting it to "Auto" in its own UI is not always enough,
since its privileged helper can keep running.

### Command authorisation

Telemetry is readable by anyone on the machine; commands are not. The daemon
checks `LOCAL_PEERCRED` on the connection and accepts `setPolicy` only from
root or the console user, logging every accepted command. This is a weaker
guarantee than the per-action authentication used for snapshot reclaim — a
process already running as you can change your fan policy without a password
— accepted deliberately, because a curve has to persist and a per-action
prompt cannot express continuous control. The hardware clamp and thermal
failsafe bound the worst case to "a fan at a speed the hardware allows".
