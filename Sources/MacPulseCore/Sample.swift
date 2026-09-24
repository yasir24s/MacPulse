import Foundation

/// One instant of machine telemetry.
///
/// MacPulse is a *monitor*, not a diagnostic: nothing here is a verdict.
/// Every field is a raw reading, and meaning comes from watching it move.
/// (Auscult is the tool that renders judgements -- about iOS devices. Keep
/// the two apart or this becomes a worse Auscult pointed at a Mac.)
public struct Sample: Codable, Sendable, Identifiable {
    public var id: Double { t }
    /// Unix epoch seconds.
    public var t: Double

    // MARK: CPU / SoC  (powermetrics, root only)
    public var pClusterMHz: Int
    public var eClusterMHz: Int
    public var cpuPowerMW: Int
    public var gpuPowerMW: Int
    /// Neural Engine rail. Zero when nothing is using the ANE -- which is the
    /// point: for on-device inference work, a flat zero means your model is
    /// silently running somewhere else.
    public var anePowerMW: Int
    /// "Nominal" | "Moderate" | "Heavy" | "Trapping" | "Sleeping"
    public var thermalPressure: String

    // MARK: Memory  (vm_stat)
    public var memFreePct: Int
    public var wiredMB: Double
    public var compressedMB: Double
    public var appMB: Double
    public var cachedMB: Double
    public var compressionsPerSec: Double
    public var decompressionsPerSec: Double

    // MARK: Swap  (sysctl + vm_stat deltas)
    public var swapTotalMB: Double
    public var swapUsedMB: Double
    public var swapInPagesPerSec: Double
    public var swapOutPagesPerSec: Double
    /// swapIn / swapOut. Approaching 1.0 means pages are being evicted and
    /// immediately faulted back -- thrash rather than useful paging. This is
    /// the number that distinguishes "swap is being used" (fine, expected on
    /// 8 GB) from "swap is eating the machine" (not fine).
    public var thrashRatio: Double
    /// Cumulative count of swapouts throttled at the filesystem queue. Climbs
    /// only when the volume cannot absorb writes -- i.e. the disk is full.
    public var swapoutThrottled: Int
    public var swapfileCount: Int

    // MARK: Thermal  (IOHIDEventSystem sensors)
    /// Hottest SoC die sensor, Celsius. nil when the private IOHID symbols
    /// could not be resolved -- the daemon degrades rather than guessing.
    public var dieTempC: Double?
    public var pmu2TempC: Double?
    public var nandTempC: Double?
    public var batteryTempC: Double?
    public var sensorCount: Int
    /// Every fan the SMC reports. Empty on fanless Macs (every Air) and
    /// whenever the SMC keys cannot be read -- deliberately empty rather than
    /// a zero RPM, because on a fan gauge zero means "stopped", which is a
    /// specific and alarming claim rather than "unknown".
    public var fans: [FanSample]
    /// Hottest few sensors, verbatim hardware names, no interpretation.
    public var topSensors: [TempSensor]

    // MARK: Storage
    public var diskFreeGB: Double
    /// Reclaimable space (snapshots, evictable caches). Finder and CleanMyMac
    /// add this to free and show the sum; the swapper cannot count on it.
    public var diskPurgeableGB: Double
    public var diskTotalGB: Double
    public var diskReadMBs: Double
    public var diskWriteMBs: Double

    // MARK: Network  (NET_RT_IFLIST2)
    /// Aggregate bytes/sec across every non-loopback interface.
    ///
    /// Loopback is excluded deliberately. lo0 carries every local IPC
    /// round-trip on the machine -- including this daemon's own socket -- and
    /// including it would swamp the only question this card answers, which is
    /// how much is actually crossing the wire.
    public var netInBps: Double
    public var netOutBps: Double

    // MARK: Power
    public var batteryPct: Int
    public var batteryCharging: Bool
    public var batteryOnAC: Bool
    /// Minutes, or nil when the OS has no estimate yet.
    public var batteryMinutesRemaining: Int?
    public var batteryHealthPct: Double
    public var batteryCycles: Int

    // MARK: Scheduler
    public var load1: Double
    public var load5: Double
    public var load15: Double
    public var processCount: Int

    /// Heaviest processes this tick, already sorted. Kept short: this rides a
    /// socket twice a second.
    public var topCPU: [ProcessSample]

    /// Heaviest processes by resident memory, already sorted.
    ///
    /// Distinct from `topCPU` and listed above it in the panel: on 8 GB the
    /// process driving the swap story is very rarely the one at the top of
    /// the CPU list, and showing only the latter answers a question nobody
    /// on this machine was asking.
    public var topMem: [ProcessSample]

    public init(
        t: Double, pClusterMHz: Int = 0, eClusterMHz: Int = 0, cpuPowerMW: Int = 0,
        gpuPowerMW: Int = 0, anePowerMW: Int = 0, thermalPressure: String = "Unknown",
        memFreePct: Int = 0, wiredMB: Double = 0, compressedMB: Double = 0,
        appMB: Double = 0, cachedMB: Double = 0, compressionsPerSec: Double = 0,
        decompressionsPerSec: Double = 0, swapTotalMB: Double = 0, swapUsedMB: Double = 0,
        swapInPagesPerSec: Double = 0, swapOutPagesPerSec: Double = 0, thrashRatio: Double = 0,
        swapoutThrottled: Int = 0, swapfileCount: Int = 0, diskFreeGB: Double = 0,
        diskTotalGB: Double = 0, diskReadMBs: Double = 0, diskWriteMBs: Double = 0,
        diskPurgeableGB: Double = 0, netInBps: Double = 0, netOutBps: Double = 0,
        dieTempC: Double? = nil, pmu2TempC: Double? = nil,
        nandTempC: Double? = nil, batteryTempC: Double? = nil, sensorCount: Int = 0,
        topSensors: [TempSensor] = [], fans: [FanSample] = [],
        batteryPct: Int = 0, batteryCharging: Bool = false, batteryOnAC: Bool = false,
        batteryMinutesRemaining: Int? = nil, batteryHealthPct: Double = 0,
        batteryCycles: Int = 0, load1: Double = 0, load5: Double = 0, load15: Double = 0,
        processCount: Int = 0, topCPU: [ProcessSample] = [],
        topMem: [ProcessSample] = []
    ) {
        self.t = t; self.pClusterMHz = pClusterMHz; self.eClusterMHz = eClusterMHz
        self.cpuPowerMW = cpuPowerMW; self.gpuPowerMW = gpuPowerMW; self.anePowerMW = anePowerMW
        self.thermalPressure = thermalPressure; self.memFreePct = memFreePct
        self.wiredMB = wiredMB; self.compressedMB = compressedMB; self.appMB = appMB
        self.cachedMB = cachedMB; self.compressionsPerSec = compressionsPerSec
        self.decompressionsPerSec = decompressionsPerSec; self.swapTotalMB = swapTotalMB
        self.swapUsedMB = swapUsedMB; self.swapInPagesPerSec = swapInPagesPerSec
        self.swapOutPagesPerSec = swapOutPagesPerSec; self.thrashRatio = thrashRatio
        self.swapoutThrottled = swapoutThrottled; self.swapfileCount = swapfileCount
        self.diskFreeGB = diskFreeGB; self.diskTotalGB = diskTotalGB
        self.diskReadMBs = diskReadMBs; self.diskWriteMBs = diskWriteMBs
        self.diskPurgeableGB = diskPurgeableGB
        self.netInBps = netInBps; self.netOutBps = netOutBps
        self.dieTempC = dieTempC
        self.pmu2TempC = pmu2TempC; self.nandTempC = nandTempC
        self.batteryTempC = batteryTempC; self.sensorCount = sensorCount
        self.topSensors = topSensors; self.fans = fans
        self.batteryPct = batteryPct; self.batteryCharging = batteryCharging
        self.batteryOnAC = batteryOnAC; self.batteryMinutesRemaining = batteryMinutesRemaining
        self.batteryHealthPct = batteryHealthPct; self.batteryCycles = batteryCycles
        self.load1 = load1; self.load5 = load5; self.load15 = load15
        self.processCount = processCount; self.topCPU = topCPU; self.topMem = topMem
    }
}

public struct TempSensor: Codable, Sendable, Hashable {
    public var name: String
    public var celsius: Double
    public init(name: String, celsius: Double) { self.name = name; self.celsius = celsius }
}

public struct FanSample: Codable, Sendable, Hashable {
    public var index: Int
    public var rpm: Double
    /// SMC F<i>Md. false = firmware curve, true = a target is being forced.
    /// Reported rather than assumed: another tool may own the fan, and
    /// MacPulse must not present someone else's setpoint as its own.
    public var forced: Bool = false
    /// SMC F<i>Tg, the commanded speed. Actual overshoots it slightly while
    /// the controller hunts -- that gap is normal, not an error.
    public var targetRPM: Double = 0
    /// Floor and ceiling as the SMC reports them. Both are needed to say
    /// anything about a raw RPM figure: 7,200 is alarming on one machine and
    /// unremarkable on another, and only the ratio travels.
    public var minRPM: Double
    public var maxRPM: Double
    public init(index: Int, rpm: Double, minRPM: Double, maxRPM: Double,
                forced: Bool = false, targetRPM: Double = 0) {
        self.index = index; self.rpm = rpm; self.minRPM = minRPM; self.maxRPM = maxRPM
        self.forced = forced; self.targetRPM = targetRPM
    }
    /// Position between floor and ceiling, 0...1.
    public var fraction: Double {
        maxRPM > minRPM ? min(max((rpm - minRPM) / (maxRPM - minRPM), 0), 1) : 0
    }
}

public struct ProcessSample: Codable, Sendable, Hashable {
    public var pid: Int
    public var name: String
    public var cpuPct: Double
    public var rssMB: Double
    public init(pid: Int, name: String, cpuPct: Double, rssMB: Double) {
        self.pid = pid; self.name = name; self.cpuPct = cpuPct; self.rssMB = rssMB
    }
}

/// Hardware ceilings for this Mac, sent once at handshake so the UI can scale
/// gauges without hard-coding a model.
public struct HostInfo: Codable, Sendable {
    public var model: String
    public var chip: String
    public var pCoreCount: Int
    public var eCoreCount: Int
    public var pCoreMaxMHz: Int
    public var eCoreMaxMHz: Int
    public var memoryGB: Double
    public init(model: String, chip: String, pCoreCount: Int, eCoreCount: Int,
                pCoreMaxMHz: Int, eCoreMaxMHz: Int, memoryGB: Double) {
        self.model = model; self.chip = chip; self.pCoreCount = pCoreCount
        self.eCoreCount = eCoreCount; self.pCoreMaxMHz = pCoreMaxMHz
        self.eCoreMaxMHz = eCoreMaxMHz; self.memoryGB = memoryGB
    }
}

/// Daemon -> app frames, newline-delimited JSON over a Unix socket.
public enum Frame: Codable, Sendable {
    case hello(HostInfo)
    case control(ControlState)
    /// Replayed ring buffer, oldest first, sent once on connect.
    case history([Sample])
    case tick(Sample)
}

public enum Transport {
    public static let socketPath = "/var/run/macpulse.sock"
    public static let sampleIntervalMS = 1000
    /// Ring buffer depth held by the daemon: 6 hours at 1 Hz.
    public static let ringCapacity = 6 * 60 * 60
    /// How much of the ring a connecting client is sent. NOT the whole ring:
    /// replaying all 21,600 samples was a single ~26 MB JSON line, live ticks
    /// only start once the replay finishes, and a client that keeps 300
    /// samples sat on "Waiting for first sample" for minutes -- the menu bar
    /// readout blank the whole time. 600 covers the app's window with slack.
    public static let replayCount = 600
}


// MARK: - Fan control

/// How a fan is being driven.
public enum FanMode: String, Codable, Sendable, CaseIterable {
    /// Hand the fan back to the SMC's own curve. Always safe, always the
    /// state the daemon restores to when anything goes wrong.
    case auto
    /// Hold one speed regardless of temperature.
    case manual
    /// Interpolate a target from die temperature.
    case curve
}

/// A temperature/speed breakpoint. Between points the target is linear; below
/// the first and above the last it is flat.
public struct CurvePoint: Codable, Sendable, Hashable, Identifiable {
    public var id: Double { tempC }
    public var tempC: Double
    public var rpm: Double
    public init(tempC: Double, rpm: Double) { self.tempC = tempC; self.rpm = rpm }
}

public struct FanPolicy: Codable, Sendable, Equatable {
    public var mode: FanMode
    /// Used when mode == .manual.
    public var manualRPM: Double
    /// Used when mode == .curve. Kept sorted by temperature.
    public var curve: [CurvePoint]

    public init(mode: FanMode = .auto, manualRPM: Double = 0, curve: [CurvePoint] = []) {
        self.mode = mode; self.manualRPM = manualRPM; self.curve = curve
    }

    /// A deliberately conservative default: silent until the die is genuinely
    /// warm, full tilt well before anything is at risk. Tuned for an M2 whose
    /// sustained load sits near 60 C.
    public static let defaultCurve: [CurvePoint] = [
        CurvePoint(tempC: 45, rpm: 1200),
        CurvePoint(tempC: 60, rpm: 2200),
        CurvePoint(tempC: 75, rpm: 4000),
        CurvePoint(tempC: 88, rpm: 7200),
    ]

    /// Target for a die temperature, clamped to the fan's own range by the
    /// caller. Flat outside the end points -- extrapolating a fan curve past
    /// its measured range is how you get a negative target.
    public func target(forDieTemp t: Double) -> Double? {
        switch mode {
        case .auto: return nil
        case .manual: return manualRPM
        case .curve:
            let pts = curve.sorted { $0.tempC < $1.tempC }
            guard let first = pts.first, let last = pts.last else { return nil }
            if t <= first.tempC { return first.rpm }
            if t >= last.tempC { return last.rpm }
            for (a, b) in zip(pts, pts.dropFirst()) where t >= a.tempC && t <= b.tempC {
                let f = (t - a.tempC) / (b.tempC - a.tempC)
                return a.rpm + f * (b.rpm - a.rpm)
            }
            return last.rpm
        }
    }
}

/// Live control state, so the UI never has to infer what the daemon is doing.
public struct ControlState: Codable, Sendable, Equatable {
    public var policy: FanPolicy
    /// True while the thermal failsafe has overridden the policy.
    public var failsafeEngaged: Bool
    /// Set when another process is driving the fan, so the UI can say so
    /// instead of fighting it silently.
    public var foreignController: String?
    public var lastError: String?
    public init(policy: FanPolicy, failsafeEngaged: Bool = false,
                foreignController: String? = nil, lastError: String? = nil) {
        self.policy = policy; self.failsafeEngaged = failsafeEngaged
        self.foreignController = foreignController; self.lastError = lastError
    }
}

/// App -> daemon. The only writes the protocol permits.
public enum Command: Codable, Sendable {
    case setPolicy(FanPolicy)
    case requestState
}
