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

        // 0666: the daemon is root, the menu bar app is not. Read-only data,
        // and the app never writes back -- the protocol is one-directional.
        chmod(path, 0o666)
        listen(fd, 8)

        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                self?.welcome(client)
            }
        }
    }

    private func welcome(_ fd: Int32) {
        lock.lock()
        let backlog = ring
        lock.unlock()
        guard send(fd, .hello(host)), send(fd, .history(backlog)) else {
            close(fd); return
        }
        lock.lock(); clients.append(fd); lock.unlock()
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
