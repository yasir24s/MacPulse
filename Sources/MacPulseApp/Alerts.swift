import Foundation
import UserNotifications
import MacPulseCore

/// Threshold watching.
///
/// A monitor that only draws charts has to be looked at, and on the machine
/// it is monitoring that is exactly when you are busy doing something else.
/// This is the part that reaches out instead.
///
/// It is still not a diagnostic. A rule fires on a *reading crossing a line
/// you set*, and says which reading and which line. It does not tell you what
/// is wrong or what to do -- keeping that boundary is what stops MacPulse
/// turning into a worse Auscult pointed at a Mac.
///
/// Two properties do all the work here:
///
/// - **Hysteresis.** Clearing uses a wider margin than firing, so a value
///   resting exactly on the threshold does not produce one alert per second.
///   `clear` is a separate predicate, never the negation of `fire`.
/// - **Cooldown.** Even a genuinely sustained condition is worth saying once.
///   Without this, a machine that is legitimately thrashing for an hour sends
///   3,600 notifications and teaches you to ignore all of them.
/// - **Ripening.** A rule may require its condition to hold continuously for
///   some time before it counts. Most interesting conditions here are normal
///   in bursts and only meaningful when sustained: a fan hits maximum during
///   any long compile, and that is the fan working, not a fault.

struct Alert: Identifiable, Equatable {
    enum Severity { case warning, critical }
    let id: String
    let title: String
    let detail: String
    let severity: Severity
}

/// The two samples a rule gets to look at. Several interesting conditions are
/// about a counter *climbing*, which a single sample cannot express.
struct AlertContext {
    let now: Sample
    let prev: Sample?
}

struct AlertRule {
    let id: String
    let title: String
    let severity: Alert.Severity
    /// How long `fire` must return non-nil *continuously* before the alert is
    /// reported at all. Zero means report on the first tick, which is right
    /// for conditions that are already unambiguous the instant they appear
    /// (a throttled swapout, a disk floor) and wrong for ones that are normal
    /// in bursts.
    var sustainFor: TimeInterval = 0
    /// How long `clear` must hold *continuously* before the alert retires.
    ///
    /// The mirror of `sustainFor`, and load-bearing for anything measured as
    /// a per-second rate. Real memory pressure is bursty at 1 Hz: a captured
    /// 25-second thrash episode on this machine contained individual seconds
    /// with `swapOut` at exactly zero, because the kernel writes swap in
    /// bursts. Retiring on the first quiet tick made the alert unreachable --
    /// 23 of 88 ticks matched, but the longest unbroken run was 8 s against a
    /// 30 s gate, so it never fired at all.
    var clearFor: TimeInterval = 0
    /// Return a detail string to fire; nil means "not firing".
    let fire: (AlertContext) -> String?
    /// Must be true before a firing alert is considered over.
    let clear: (AlertContext) -> Bool
}

final class AlertEngine {
    /// Alert id -> when the condition was *first* seen. Not reset by a gap:
    /// ripening measures how long the episode has been going, not how long
    /// the predicate has been unbroken.
    private var firstFired: [String: Date] = [:]
    /// Alert id -> the most recent tick whose `fire` returned a detail.
    private var lastFired: [String: Date] = [:]
    /// Last detail seen, so the banner stays informative through a gap.
    private var lastDetail: [String: String] = [:]
    /// Alert id -> when we last sent a notification for it.
    private var lastNotified: [String: Date] = [:]
    private let cooldown: TimeInterval = 300
    private var askedForPermission = false

    /// Injectable so recorded history can be replayed against the engine at
    /// full speed instead of in real time.
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    // UNUserNotificationCenter traps outright in a process with no bundle,
    // which is exactly what `swift run MacPulseApp` is. Fail soft so the app
    // stays debuggable outside the .app wrapper.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestPermissionOnce() {
        guard !askedForPermission, let center else { return }
        askedForPermission = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Evaluate every rule against this tick and return what is currently
    /// firing, newest first. Side effect: posts notifications, rate-limited.
    func evaluate(_ ctx: AlertContext) -> [Alert] {
        var out: [Alert] = []
        let t = now()
        for rule in AlertEngine.rules {
            if let detail = rule.fire(ctx) {
                if firstFired[rule.id] == nil { firstFired[rule.id] = t }
                lastFired[rule.id] = t
                lastDetail[rule.id] = detail
            }
            guard let since = firstFired[rule.id] else { continue }

            // Retire only once the clear predicate holds *and* the condition
            // has been quiet for clearFor. Both halves matter: clear() alone
            // retires on a single bursty zero, and quiet alone would retire a
            // condition that is still plainly true but momentarily flat.
            let quietFor = t.timeIntervalSince(lastFired[rule.id] ?? since)
            if quietFor >= rule.clearFor, rule.clear(ctx) {
                firstFired.removeValue(forKey: rule.id)
                lastFired.removeValue(forKey: rule.id)
                lastDetail.removeValue(forKey: rule.id)
                lastNotified.removeValue(forKey: rule.id)
                continue
            }

            // Still ripening: the condition holds but not yet for long enough
            // to be worth your attention. Tracked, not reported.
            guard t.timeIntervalSince(since) >= rule.sustainFor else { continue }
            let alert = Alert(id: rule.id, title: rule.title,
                              detail: lastDetail[rule.id] ?? "holding",
                              severity: rule.severity)
            out.append(alert)
            notifyIfDue(alert, at: t)
        }
        return out.sorted { ($0.severity == .critical ? 0 : 1) < ($1.severity == .critical ? 0 : 1) }
    }

    private func notifyIfDue(_ alert: Alert, at t: Date) {
        if let last = lastNotified[alert.id], t.timeIntervalSince(last) < cooldown { return }
        lastNotified[alert.id] = t
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail
        content.sound = alert.severity == .critical ? .default : nil
        center.add(UNNotificationRequest(identifier: "\(alert.id)-\(Date().timeIntervalSince1970)",
                                         content: content, trigger: nil))
    }

    // MARK: - the rules

    static let rules: [AlertRule] = [
        // Cumulative counter: the *climb* is the event, not the value. A
        // machine that throttled swapouts once last Tuesday is not a machine
        // in trouble now.
        AlertRule(
            id: "swapout-throttled",
            title: "Swapouts throttled",
            severity: .critical,
            fire: { ctx in
                guard let prev = ctx.prev else { return nil }
                let delta = ctx.now.swapoutThrottled - prev.swapoutThrottled
                guard delta > 0 else { return nil }
                return "\(delta) in the last second — the volume cannot absorb swap writes. "
                     + String(format: "%.1f GB free.", ctx.now.diskFreeGB)
            },
            // Needs a full minute of not climbing, not just one quiet tick.
            clear: { $0.now.swapoutThrottled == $0.prev?.swapoutThrottled }
        ),

        // The upstream cause of the above, per the storage note in the README.
        AlertRule(
            id: "disk-floor",
            title: "Disk nearly full",
            severity: .critical,
            fire: { ctx in
                guard ctx.now.diskFreeGB < 10 else { return nil }
                return String(format: "%.1f GB free. Swap needs room to grow.", ctx.now.diskFreeGB)
            },
            // Fires at 10, clears at 15: a disk hovering at 10.0 must not
            // chatter.
            clear: { $0.now.diskFreeGB > 15 }
        ),

        AlertRule(
            id: "thermal",
            title: "Thermal pressure",
            severity: .warning,
            fire: { ctx in
                let p = ctx.now.thermalPressure
                guard p == "Heavy" || p == "Trapping" || p == "Sleeping" else { return nil }
                return "\(p) — the OS is taking performance away."
            },
            // Only a return to Nominal clears it; "Moderate" is still elevated.
            clear: { $0.now.thermalPressure == "Nominal" }
        ),

        // A fan at its ceiling is not a fault -- it is the cooling system
        // doing exactly its job -- so this is a warning, and it has to hold
        // for two minutes first. Every sustained compile pins this fan; only
        // one that stays pinned is telling you something.
        AlertRule(
            id: "fan-max",
            title: "Fan at maximum",
            severity: .warning,
            sustainFor: 120,
            fire: { ctx in
                guard let f = ctx.now.fans.max(by: { $0.fraction < $1.fraction }),
                      f.fraction >= 0.95 else { return nil }
                return String(format: "%.0f rpm — %.0f%% of its %.0f–%.0f range, held for 2 min.",
                              f.rpm, f.fraction * 100, f.minRPM, f.maxRPM)
            },
            // Fires at 95% of range, clears at 75%: a fan oscillating around
            // its ceiling must not reopen the alert every few seconds. A Mac
            // with no fans reports none, so this can never fire on an Air.
            clear: { ctx in
                guard let f = ctx.now.fans.max(by: { $0.fraction < $1.fraction }) else { return true }
                return f.fraction < 0.75
            }
        ),

        thrashRule,
    ]

    /// Sustained thrash: pages evicted to swap and immediately faulted back.
    ///
    /// Thresholds are calibrated against 498 samples of this machine's own
    /// history rather than chosen for roundness. In that window `swapOut` was
    /// zero at the 99th percentile, `thrashRatio` cleared 0.5 in exactly one
    /// tick out of 498, and the longest consecutive run above any candidate
    /// threshold was one second. So:
    ///
    /// - **Ratio alone is useless.** It is `min(in/out, 2.0)` and defined as
    ///   zero whenever `out` is zero, so it reads 0.00 almost always and hits
    ///   1.0 on two swapins against two swapouts -- a perfectly idle machine.
    ///   The absolute rate gate is what makes it mean anything.
    /// - **100 pages/s** of swapouts is ~1.6 MB/s at this page size: small
    ///   enough to catch real pressure early, far above anything observed at
    ///   rest.
    /// - **0.7, not 1.0.** Evicting 100 pages and faulting 70 back is already
    ///   thrash; waiting for parity would miss most of it. The 2.0 cap means
    ///   "faulting back far more than we evict" also clears this bar, which is
    ///   correct -- that is thrash too.
    /// - **30 s sustained.** Xcode starting up thrashes for a few seconds and
    ///   that is just what a build does. Against the observed data -- longest
    ///   run one second -- this has a thirtyfold margin, which is why the
    ///   replay test over that history fires zero times.
    ///
    /// Clearing is deliberately wide on *both* axes: half the rate, or a ratio
    /// well under the fire line. A machine oscillating around 100 pages/s must
    /// not reopen this every few seconds.
    static let thrashRule = AlertRule(
        id: "thrash",
        title: "Memory thrashing",
        severity: .critical,
        sustainFor: 30,
        // 20 s of genuine quiet before retiring. Measured against a real
        // episode: swapouts stop for up to three consecutive seconds mid-
        // thrash, so anything under ~5 s here makes the 30 s gate unreachable.
        clearFor: 20,
        fire: { ctx in
            let out = ctx.now.swapOutPagesPerSec
            let ratio = ctx.now.thrashRatio
            guard out >= 100, ratio >= 0.7 else { return nil }
            return String(format: "%.0f pages/s out, %.0f in (ratio %.2f) for 30 s — "
                                + "pages are being evicted and faulted straight back.",
                          out, ctx.now.swapInPagesPerSec, ratio)
        },
        clear: { ctx in
            ctx.now.swapOutPagesPerSec < 50 || ctx.now.thrashRatio < 0.3
        }
    )
}
