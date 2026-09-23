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
    /// Return a detail string to fire; nil means "not firing".
    let fire: (AlertContext) -> String?
    /// Must be true before a firing alert is considered over.
    let clear: (AlertContext) -> Bool
}

final class AlertEngine {
    /// Alert id -> when it started firing.
    private var active: [String: Date] = [:]
    /// Alert id -> when we last sent a notification for it.
    private var lastNotified: [String: Date] = [:]
    private let cooldown: TimeInterval = 300
    private var askedForPermission = false

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
        for rule in AlertEngine.rules {
            let detail = rule.fire(ctx)
            let isActive = active[rule.id] != nil

            if let detail {
                if !isActive { active[rule.id] = Date() }
                let alert = Alert(id: rule.id, title: rule.title,
                                  detail: detail, severity: rule.severity)
                out.append(alert)
                notifyIfDue(alert)
            } else if isActive, rule.clear(ctx) {
                // Only a satisfied clear predicate retires an alert. A rule
                // whose fire() merely stopped returning a detail stays active,
                // which is what gives the hysteresis its teeth.
                active.removeValue(forKey: rule.id)
                lastNotified.removeValue(forKey: rule.id)
            } else if isActive {
                out.append(Alert(id: rule.id, title: rule.title,
                                 detail: "holding", severity: rule.severity))
            }
        }
        return out.sorted { ($0.severity == .critical ? 0 : 1) < ($1.severity == .critical ? 0 : 1) }
    }

    private func notifyIfDue(_ alert: Alert) {
        if let last = lastNotified[alert.id], Date().timeIntervalSince(last) < cooldown { return }
        lastNotified[alert.id] = Date()
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

        thrashRule,
    ]

    /// TODO(yasir): the one rule that needs your judgement rather than mine.
    ///
    /// Everything above keys off something objective -- a counter climbed, a
    /// disk hit a floor, the OS said it is throttling. Thrash has no such
    /// line. `thrashRatio` is swapins/swapouts clamped to 2.0, and the README
    /// already says ratio near 1.0 means pages are evicted and immediately
    /// faulted back. What it does not say is when that is worth interrupting
    /// you, and that is a genuine judgement call with real trade-offs:
    ///
    /// - **Ratio alone is not enough.** At 2 swapins and 2 swapouts per second
    ///   the ratio is a perfect 1.0 and nothing is wrong. You almost certainly
    ///   want to gate on absolute rate too -- say `swapOutPagesPerSec > N` --
    ///   or the alert fires on an idle machine.
    /// - **Duration matters more than instant.** Xcode starting up will thrash
    ///   for four seconds and that is just what a build does. Sustained thrash
    ///   is the signal. You have `ctx.prev` for one tick back; for a longer
    ///   window this rule would need its own state.
    /// - **Pick the clear margin deliberately.** Firing at 0.8 and clearing at
    ///   0.8 gives you a rule that chatters all afternoon.
    ///
    /// Fill in `fire` and `clear` below. Returning nil from `fire` (as it does
    /// now) simply means the rule never fires, so the app is fully working
    /// until you do.
    static let thrashRule = AlertRule(
        id: "thrash",
        title: "Memory thrashing",
        severity: .critical,
        fire: { ctx in
            _ = ctx
            return nil
        },
        clear: { _ in true }
    )
}
