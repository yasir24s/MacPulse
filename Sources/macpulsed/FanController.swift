import Darwin
import Foundation
import MacPulseCore

/// Owns the fan. Everything dangerous about this feature is in here.
///
/// The governing rule is that `auto` -- handing the fan back to the SMC's own
/// curve -- is the resting state, and every failure path leads to it. A fan
/// tool's worst outcome is not "wrong speed", it is "forced to a low speed
/// with nothing left supervising it": the daemon dies, `F0Md` stays 1, and
/// the machine cooks quietly under a firmware curve that is no longer in
/// control. So the failsafe is not a feature bolted on at the end, it is the
/// default that the policy is allowed to temporarily override.
final class FanController {

    /// Die temperature at which the policy is abandoned and the firmware
    /// takes over, whatever the user asked for.
    private static let failsafeEngageC = 90.0
    /// Hysteresis: well below engage, so a machine sitting at the threshold
    /// does not oscillate between policy and firmware every tick.
    private static let failsafeClearC = 80.0
    /// Writing the same target every second is pointless SMC traffic; only
    /// write when the target actually moves by more than this.
    private static let rpmEpsilon = 25.0

    private let fans: SMCFans
    private let lock = NSLock()
    private var policy: FanPolicy
    private var failsafe = false
    private var lastWritten: [Int: Double] = [:]
    private var foreign: String?
    private var lastError: String?
    private let storePath = "/var/db/com.yasir.macpulse.policy.json"

    init(fans: SMCFans) {
        self.fans = fans
        self.policy = Self.loadPolicy(from: storePath) ?? FanPolicy()
        installFailsafeHandlers()
    }

    var state: ControlState {
        lock.lock(); defer { lock.unlock() }
        return ControlState(policy: policy, failsafeEngaged: failsafe,
                            foreignController: foreign, lastError: lastError)
    }

    func setPolicy(_ new: FanPolicy) {
        lock.lock()
        policy = new
        lastWritten.removeAll()      // force a write on the next tick
        lock.unlock()
        save()
        // Releasing immediately rather than waiting for the next tick means
        // "Auto" in the UI is instant, which matters when someone is reaching
        // for it because the machine is loud.
        if new.mode == .auto {
            for i in 0..<fans.fanCount { fans.releaseToAuto(i) }
        }
    }

    /// Called once per sample with the current die temperature.
    func apply(dieTempC: Double?, fansNow: [FanSample]) {
        lock.lock()
        let mode = policy.mode
        let pol = policy
        var engaged = failsafe
        lock.unlock()

        // 1. Failsafe, evaluated before anything else and independent of mode.
        if let t = dieTempC {
            if !engaged && t >= Self.failsafeEngageC {
                engaged = true
                log("failsafe ENGAGED at \(String(format: "%.1f", t))C -- releasing fans to firmware")
            } else if engaged && t <= Self.failsafeClearC {
                engaged = false
                log("failsafe cleared at \(String(format: "%.1f", t))C")
            }
        }

        // 2. A curve without a temperature is not a curve. Losing the sensor
        //    path must degrade to firmware control, never to a stale target.
        let blind = (mode == .curve && dieTempC == nil)
        if blind { note("no die temperature; curve cannot run") }

        lock.lock(); failsafe = engaged; lock.unlock()

        guard !engaged, !blind, mode != .auto else {
            releaseAll()
            return
        }

        // 3. Compute and clamp. The clamp is the hardware's own reported
        //    range -- not a constant -- so this cannot command a speed the
        //    fan does not support.
        guard let raw = pol.target(forDieTemp: dieTempC ?? 0) else { releaseAll(); return }
        for f in fansNow {
            let target = min(max(raw, f.minRPM), f.maxRPM)
            lock.lock(); let prev = lastWritten[f.index]; lock.unlock()
            if let prev, abs(prev - target) < Self.rpmEpsilon { continue }
            if fans.force(f.index, rpm: target) {
                lock.lock(); lastWritten[f.index] = target; lock.unlock()
            } else {
                note("SMC write failed for fan \(f.index)")
            }
        }
    }

    /// Note when someone else is driving: we are in auto, yet the fan reports
    /// forced. Surfaced rather than silently overwritten -- two controllers
    /// fighting over one key is worse than one controller and a warning.
    func detectForeignController(_ fansNow: [FanSample]) {
        lock.lock(); let mine = policy.mode != .auto || failsafe; lock.unlock()
        guard !mine else { lock.lock(); foreign = nil; lock.unlock(); return }
        let contested = fansNow.contains { $0.forced }
        lock.lock()
        foreign = contested ? (Self.runningFanTool() ?? "another process") : nil
        lock.unlock()
    }

    private static func runningFanTool() -> String? {
        let known = ["Macs Fan Control": "macsfancontrol",
                     "TG Pro": "TGPro",
                     "iStat Menus": "iStat"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Axo", "comm="]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return known.first { out.localizedCaseInsensitiveContains($0.value) }?.key
    }

    // MARK: - unwinding

    func releaseAll() {
        for i in 0..<fans.fanCount { fans.releaseToAuto(i) }
        lock.lock(); lastWritten.removeAll(); lock.unlock()
    }

    /// Restore firmware control on every exit path we can observe. atexit
    /// covers a clean return; the signal handlers cover launchd stopping us
    /// and a terminal ctrl-c. SIGKILL cannot be caught -- which is precisely
    /// why the failsafe above must also be able to save the machine without
    /// this ever running.
    private func installFailsafeHandlers() {
        FanController.shared = self
        atexit { FanController.shared?.releaseAll() }
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGQUIT] {
            signal(sig) { _ in
                FanController.shared?.releaseAll()
                _exit(0)
            }
        }
    }
    private nonisolated(unsafe) static var shared: FanController?

    // MARK: - persistence

    private func save() {
        lock.lock(); let p = policy; lock.unlock()
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: URL(fileURLWithPath: storePath), options: .atomic)
    }

    private static func loadPolicy(from path: String) -> FanPolicy? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(FanPolicy.self, from: d)
    }

    // MARK: - logging

    private func note(_ s: String) {
        lock.lock(); lastError = s; lock.unlock()
        log(s)
    }
    private func log(_ s: String) {
        FileHandle.standardError.write(Data("macpulsed: \(s)\n".utf8))
    }
}
