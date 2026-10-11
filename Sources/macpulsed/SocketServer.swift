import Darwin
import Foundation
import MacPulseCore

/// Unix-socket fan-out. Newline-delimited JSON, one `Frame` per line.
///
/// A Unix socket rather than TCP on loopback: this daemon runs as root and a
/// listening TCP port -- even bound to 127.0.0.1 -- is reachable by every
/// process and container on the machine. Filesystem permissions on the socket
/// are a real access control; a loopback bind is not.
final class SocketServer {

    private let path: String
    private let lock = NSLock()
    private var clients: [Int32] = []
    private var ring: [Sample] = []
    private let capacity: Int
    private let host: HostInfo
    private let encoder = JSONEncoder()

    /// Invoked for a command that passed the peer check. Returns the state
    /// to echo back.
    var onCommand: ((Command) -> ControlState)?
    /// Current control state, for the handshake.
    var currentState: (() -> ControlState)?

    init(path: String, capacity: Int, host: HostInfo) {
        self.path = path
        self.capacity = capacity
        self.host = host
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EADDRNOTAVAIL) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            path.withCString {
                strncpy(UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self),
                        $0, capacity - 1)
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }

        // 0666: the daemon is root, the menu bar app is not. Any local user can
        // connect and read telemetry; commands are gated per connection by
        // peerAuthorised (LOCAL_PEERCRED), not by these file permissions.
        chmod(path, 0o666)
        listen(fd, 8)

        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                // A client that stops reading must not be able to wedge the
                // accept loop. Without this a single stuck peer blocked EVERY
                // subsequent connection -- new clients got no frames at all,
                // not even hello, because the loop never came back round.
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &tv,
                           socklen_t(MemoryLayout<timeval>.size))
                // Replaying the ring can be megabytes; do it off the accept
                // thread so a slow reader delays only itself.
                Thread.detachNewThread { self?.welcome(client) }
            }
        }
    }

    private func welcome(_ fd: Int32) {
        lock.lock()
        let backlog = Array(ring.suffix(Transport.replayCount))
        lock.unlock()
        guard send(fd, .hello(host)), send(fd, .history(backlog)) else {
            close(fd); return
        }
        if let st = currentState?(), !send(fd, .control(st)) { close(fd); return }
        lock.lock(); clients.append(fd); lock.unlock()
        readCommands(from: fd)
    }

    /// The write path is open to any local reader -- telemetry is harmless.
    /// The *command* path is not: this daemon is root, so a command is only
    /// honoured from the console user or root itself. Without this, any
    /// sandboxed helper running on the machine could set your fan.
    private func peerAuthorised(_ fd: Int32) -> Bool {
        var cred = xucred()
        var len = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) == 0,
              cred.cr_version == XUCRED_VERSION else { return false }
        let uid = cred.cr_uid
        if uid == 0 { return true }
        var st = stat()
        guard stat("/dev/console", &st) == 0 else { return false }
        return uid == st.st_uid
    }

    private func readCommands(from fd: Int32) {
        let authorised = peerAuthorised(fd)
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        let decoder = JSONDecoder()
        while true {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            buf.append(contentsOf: chunk[0..<n])
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf[buf.startIndex..<nl]
                buf.removeSubrange(buf.startIndex...nl)
                guard let cmd = try? decoder.decode(Command.self, from: Data(line)) else { continue }
                guard authorised else {
                    FileHandle.standardError.write(Data(
                        "macpulsed: rejected command from unauthorised peer\n".utf8))
                    continue
                }
                // Every accepted command is logged. A root daemon that can be
                // driven should leave a record of who drove it.
                FileHandle.standardError.write(Data("macpulsed: command \(cmd)\n".utf8))
                if let st = onCommand?(cmd) { _ = send(fd, .control(st)) }
            }
        }
        lock.lock(); clients.removeAll { $0 == fd }; lock.unlock()
        close(fd)
    }

    /// Push a control-state change to everyone.
    func broadcastState(_ st: ControlState) {
        lock.lock(); let targets = clients; lock.unlock()
        for fd in targets { _ = send(fd, .control(st)) }
    }

    func broadcast(_ sample: Sample) {
        lock.lock()
        ring.append(sample)
        if ring.count > capacity { ring.removeFirst(ring.count - capacity) }
        let targets = clients
        lock.unlock()

        var dead: [Int32] = []
        for fd in targets where !send(fd, .tick(sample)) { dead.append(fd) }
        guard !dead.isEmpty else { return }
        lock.lock()
        clients.removeAll { dead.contains($0) }
        lock.unlock()
        dead.forEach { close($0) }
    }

    private func send(_ fd: Int32, _ frame: Frame) -> Bool {
        guard var data = try? encoder.encode(frame) else { return true }
        data.append(0x0A)
        return data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
    }
}
