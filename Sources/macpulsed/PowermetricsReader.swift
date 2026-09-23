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

    init(onSample: @escaping (Reading) -> Void) {
        self.onSample = onSample
    }

    func start(intervalMS: Int) {
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
            onSample(r)
            r = Reading()
        }
    }
}
