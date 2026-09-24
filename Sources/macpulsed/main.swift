import Darwin
import Foundation
import MacPulseCore

// A dead client mid-write must not take the daemon down with it.
signal(SIGPIPE, SIG_IGN)

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("macpulsed must run as root (powermetrics does).\n".utf8))
    exit(1)
}

var sampler = SystemSampler()
let host = sampler.hostInfo()

// Control gets its own SMC connection. Independent of the sampler's, so a
// stalled read path can never leave the fan stuck in a forced state.
let controller = SMCFans().map { FanController(fans: $0) }
if controller == nil {
    FileHandle.standardError.write(Data("macpulsed: no fan control (fanless or SMC unavailable)\n".utf8))
}
let server = SocketServer(path: Transport.socketPath,
                          capacity: Transport.ringCapacity,
                          host: host)
do { try server.start() } catch {
    FileHandle.standardError.write(Data("macpulsed: cannot bind \(Transport.socketPath): \(error)\n".utf8))
    exit(1)
}
// Ring depth and replay cap in the startup line: a 26 MB replay once blocked
// every client's first tick for minutes, and the log had nothing to say why.
FileHandle.standardError.write(Data(
    "macpulsed: listening on \(Transport.socketPath) (ring \(Transport.ringCapacity), replay \(Transport.replayCount))\n".utf8))

server.currentState = { controller?.state ?? ControlState(policy: FanPolicy()) }
server.onCommand = { cmd in
    switch cmd {
    case .setPolicy(let p): controller?.setPolicy(p)
    case .requestState: break
    }
    return controller?.state ?? ControlState(policy: FanPolicy())
}

// powermetrics sets the clock: it blocks for its full interval, so letting it
// drive avoids a second timer drifting against it and interleaving samples.
let reader = PowermetricsReader { reading in
    var s = Sample(t: Date().timeIntervalSince1970)
    s.pClusterMHz = reading.pMHz
    s.eClusterMHz = reading.eMHz
    s.cpuPowerMW = reading.cpuMW
    s.gpuPowerMW = reading.gpuMW
    s.anePowerMW = reading.aneMW
    s.thermalPressure = reading.pressure
    sampler.sample(into: &s)

    // Control runs from the same tick as the telemetry it reacts to, so the
    // temperature a target was computed from is exactly the one reported
    // alongside it. A separate timer would let the two drift apart and make
    // the curve impossible to reason about from the charts.
    if let c = controller {
        c.detectForeignController(s.fans)
        c.apply(dieTempC: s.dieTempC, fansNow: s.fans)
        server.broadcastState(c.state)
    }

    server.broadcast(s)
}
reader.start(intervalMS: Transport.sampleIntervalMS)

dispatchMain()
