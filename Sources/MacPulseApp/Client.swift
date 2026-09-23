import Darwin
import Foundation
import MacPulseCore

/// Reads the daemon's newline-delimited JSON stream off the Unix socket.
///
/// Reconnects on its own: the daemon is a LaunchDaemon that may restart under
/// us (update, crash, sleep/wake), and a menu bar item that silently stops
/// updating is worse than one that says it is disconnected.
@MainActor
final class Client: ObservableObject {
    @Published private(set) var host: HostInfo?
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var connected = false
    /// Nil until the daemon reports control state. Distinguishes "no fan
    /// control on this machine" from "not connected yet", which the UI must
    /// not conflate.
    @Published private(set) var control: ControlState?
    /// Currently firing threshold alerts, critical first.
    @Published private(set) var alerts: [Alert] = []

    /// Set when frames arrive but none of them decode -- which in practice
    /// means /usr/local/libexec/macpulsed is older than this app and is not
    /// sending fields the current Sample requires. Worth naming explicitly:
    /// the symptom is otherwise a connected socket that never produces a
    /// sample, which looks exactly like a daemon that has quietly wedged.
    @Published private(set) var protocolMismatch = false

    private let engine = AlertEngine()

    /// Rolling window kept in the UI. The daemon holds 6 h; the menu only ever
    /// draws minutes, and retaining all of it would cost more than the app.
    private let windowSize = 300
    /// Held so commands can be written back on the same connection the
    /// telemetry arrives on -- the daemon authorises per-peer, so a second
    /// connection would have to be authorised again for no benefit.
    ///
    /// Boxed outside actor isolation on purpose: the reader runs on its own
    /// thread and must set this, while `send` is called from the main actor.
    private let sock = FDBox()

    var latest: Sample? { samples.last }

    func start() {
        engine.requestPermissionOnce()
        Thread.detachNewThread { [weak self] in
            while true {
                self?.connectAndRead()
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private nonisolated func connectAndRead() {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            Transport.socketPath.withCString {
                strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self),
                        $0, capacity - 1)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, len) }
        }
        guard ok == 0 else { close(s); return }

        sock.value = s
        Task { @MainActor in self.connected = true }
        defer {
            sock.value = -1
            close(s)
            Task { @MainActor in
                self.connected = false
                self.control = nil
            }
        }

        let decoder = JSONDecoder()
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var undecodable = 0
        while true {
            let n = read(s, &chunk, chunk.count)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let frame = try? decoder.decode(Frame.self, from: Data(line)) else {
                    // A couple of rejects could be a truncated first read.
                    // A steady stream of them is a version skew.
                    undecodable += 1
                    if undecodable >= 3 {
                        Task { @MainActor in self.protocolMismatch = true }
                    }
                    continue
                }
                undecodable = 0
                Task { @MainActor in
                    self.protocolMismatch = false
                    self.apply(frame)
                }
            }
        }
    }

    /// Fire-and-forget: the daemon answers with a `.control` frame on the
    /// same socket, so there is nothing to await here.
    func send(_ command: Command) {
        guard var data = try? JSONEncoder().encode(command) else { return }
        data.append(0x0A)
        let s = sock.value
        guard s >= 0 else { return }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(s, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    private func apply(_ frame: Frame) {
        switch frame {
        case .hello(let h):
            host = h
        case .history(let batch):
            samples = Array(batch.suffix(windowSize))
        case .control(let c):
            control = c
        case .tick(let s):
            let prev = samples.last
            samples.append(s)
            if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
            // Evaluated on the tick rather than in the view: the panel is
            // closed almost all the time, and an alert you only get when you
            // are already looking is not an alert.
            alerts = engine.evaluate(AlertContext(now: s, prev: prev))
        }
    }
}


/// Lock-guarded file descriptor shared between the reader thread and the
/// main actor.
final class FDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32 = -1
    var value: Int32 {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
