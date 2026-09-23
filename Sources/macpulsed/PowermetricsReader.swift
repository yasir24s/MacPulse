import Foundation

/// Streams `powermetrics` and emits one dictionary per sample block.
///
/// powermetrics is the only reason this daemon needs root. It is also the only
/// source for the ANE rail and for thermal pressure -- there is no SMC sampler
/// on Apple Silicon, so die temperature is simply not obtainable here and the
/// UI must not pretend otherwise.
final class PowermetricsReader {

    struct Reading {
        var pMHz = 0, eMHz = 0, cpuMW = 0, gpuMW = 0, aneMW = 0
        var pressure = "Unknown"
    }

    private var process: Process?
    private let onSample: (Reading) -> Void
    /// Last time a sample block was parsed. A powermetrics that stops emitting
    /// WITHOUT exiting is invisible to terminationHandler -- observed after a
    /// sleep/wake on a 17 h-old daemon, child alive and silent, every chart
    /// frozen. Liveness has to be measured, not inferred from the process
    /// still existing.
    private let lastSample = Atomic(Date())
    private var intervalMS = 1000
    /// The watchdog is started once for the life of the reader. start() is
    /// re-entered on every restart, and spawning a thread there leaked one
    /// per cycle -- three watchdogs all racing to kill the same child.
    private var watchdogStarted = false

    init(onSample: @escaping (Reading) -> Void) {
        self.onSample = onSample
    }

    func start(intervalMS: Int) {
        self.intervalMS = intervalMS
        // Reset liveness BEFORE spawning. Without this the restarted child
        // inherits the stale timestamp that triggered the kill, so the
        // watchdog shoots it before it can emit a first sample -- an
        // infinite kill loop in which powermetrics is never alive long
        // enough to clear the very condition being watched for.
        lastSample.value = Date()
        if !watchdogStarted {
            watchdogStarted = true
            startWatchdog()
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        p.arguments = [
            "--samplers", "cpu_power,gpu_power,ane_power,thermal",
            "-i", String(intervalMS),
        ]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        process = p

        // powermetrics never exits; if it dies (SIGKILL, sleep/wake) restart it
        // rather than silently going flat -- a frozen chart looks like an idle
        // machine, which is the most misleading failure this tool could have.
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Thread.sleep(forTimeInterval: 2)
            self.start(intervalMS: intervalMS)
        }

        do { try p.run() } catch {
            FileHandle.standardError.write(Data("macpulsed: cannot run powermetrics: \(error)\n".utf8))
            return
        }

        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            var pending = Reading()
            var buffer = Data()
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    self.consume(line, into: &pending)
                }
            }
        }
    }

    /// Kill a silent child so terminationHandler restarts it. Ten missed
    /// intervals is well clear of normal jitter and still catches a stall
    /// inside a few seconds at 1 Hz.
    private func startWatchdog() {
        Thread.detachNewThread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 5)
                guard let self else { return }
                let quiet = Date().timeIntervalSince(self.lastSample.value)
                // powermetrics takes a full interval to emit its first block,
                // and longer on a loaded machine; 20 s is the floor so a cold
                // start is never mistaken for a stall.
                let limit = max(Double(self.intervalMS) / 1000 * 10, 20)
                if quiet > limit, let p = self.process, p.isRunning {
                    FileHandle.standardError.write(Data(
                        "macpulsed: powermetrics silent for \(Int(quiet))s, restarting\n".utf8))
                    p.terminate()
                    kill(p.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func consume(_ line: String, into r: inout Reading) {
        func intAfter(_ prefix: String) -> Int? {
            guard let range = line.range(of: prefix) else { return nil }
            let rest = line[range.upperBound...]
            let digits = rest.drop { !$0.isNumber }.prefix { $0.isNumber }
            return Int(digits)
        }

        if line.contains("E-Cluster HW active frequency") {
            r.eMHz = intAfter("frequency:") ?? r.eMHz
        } else if line.contains("P-Cluster HW active frequency") {
            r.pMHz = intAfter("frequency:") ?? r.pMHz
        } else if line.hasPrefix("CPU Power") {
            r.cpuMW = intAfter("Power:") ?? r.cpuMW
        } else if line.hasPrefix("GPU Power") {
            r.gpuMW = intAfter("Power:") ?? r.gpuMW
        } else if line.hasPrefix("ANE Power") {
            r.aneMW = intAfter("Power:") ?? r.aneMW
        } else if line.contains("Current pressure level") {
            // Closes a sample block.
            if let colon = line.lastIndex(of: ":") {
                r.pressure = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
            lastSample.value = Date()
            onSample(r)
            r = Reading()
        }
    }
}


/// Minimal lock-guarded box. The watchdog and the parser thread both touch
/// the liveness timestamp.
final class Atomic<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ v: T) { stored = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
