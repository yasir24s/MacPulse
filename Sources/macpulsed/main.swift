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
let server = SocketServer(path: Transport.socketPath,
                          capacity: Transport.ringCapacity,
                          host: host)
do { try server.start() } catch {
    FileHandle.standardError.write(Data("macpulsed: cannot bind \(Transport.socketPath): \(error)\n".utf8))
    exit(1)
}
FileHandle.standardError.write(Data("macpulsed: listening on \(Transport.socketPath)\n".utf8))

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
    server.broadcast(s)
}
reader.start(intervalMS: Transport.sampleIntervalMS)

dispatchMain()
