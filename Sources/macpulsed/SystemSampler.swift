import Darwin
import Foundation
import IOKit
import IOKit.ps
import MacPulseCore

/// Everything readable without powermetrics.
///
/// Deliberately uses Mach / IOKit / sysctl directly rather than shelling out
/// to vm_stat and iostat. At 1 Hz forever, spawning two processes per tick is
/// ~170k forks a day on a machine that is already memory-starved -- the
/// monitor would become a measurable part of what it is monitoring.
struct SystemSampler {

    private var prevVM: vm_statistics64_data_t?
    private var prevDiskRead: UInt64 = 0
    private var prevDiskWrite: UInt64 = 0
    private var prevNetIn: UInt32 = 0
    private var prevNetOut: UInt32 = 0
    private var hasNetBaseline = false
    private var prevStamp: Double = Date().timeIntervalSince1970
    private var tick = 0
    private var cachedCPU: [ProcessSample] = []
    private var cachedMem: [ProcessSample] = []
    private var cachedProcCount = 0
    /// Per-process CPU time (mach units) at the previous sweep, for deltas.
    private var prevProcCPU: [pid_t: UInt64] = [:]
    private var prevProcStamp: Double = 0
    /// pti_total_* are mach absolute units, not ns, on Apple Silicon (125/3).
    private let nsPerMach: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    // Cadence. Measured at the daemon's real 1 Hz (cold caches every call):
    // the purgeable lookup cost 12.8 ms and battery 0.5 ms per tick, for
    // values that change over minutes. Reading them every second was most of
    // the daemon's own CPU. Refresh on these multiples of the tick instead.
    private static let slowEvery = 10
    private static let purgeableEvery = 30
    private var cachedPurgeableGB = 0.0
    private var cachedSwapfiles = 0
    private var cachedBattery: (pct: Int, charging: Bool, ac: Bool, mins: Int?,
                                health: Double, cycles: Int)?
    private func due(_ every: Int) -> Bool { tick == 1 || tick % every == 0 }
    /// nil if the private IOHID symbols are unavailable on this OS.
    private let thermal = Thermal()
    /// nil on a fanless Mac or if the SMC will not open.
    private let fans = SMCFans()

    private let pageSize: Double = {
        var sz: vm_size_t = 0
        host_page_size(mach_host_self(), &sz)
        return Double(sz)
    }()

    // MARK: - sysctl helpers

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private func swapUsage() -> (total: Double, used: Double) {
        var xsw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return (0, 0) }
        return (Double(xsw.xsu_total) / 1_048_576, Double(xsw.xsu_used) / 1_048_576)
    }

    // MARK: - virtual memory

    private func vmStats() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? stats : nil
    }

    // MARK: - storage

    /// statvfs only -- a single syscall, cheap enough for every tick.
    private func diskSpace() -> (free: Double, total: Double) {
        var st = statvfs()
        guard statvfs("/System/Volumes/Data", &st) == 0 else { return (0, 0) }
        let frsize = Double(st.f_frsize)
        return (Double(st.f_bavail) * frsize / 1e9, Double(st.f_blocks) * frsize / 1e9)
    }

    /// Finder/CleanMyMac report ...ForImportantUsage, which folds in
    /// purgeable space. Track the gap explicitly so the two numbers never look
    /// like a contradiction -- and so the swap story stays honest: purgeable
    /// needs reclaim, and reclaim is what failed under pressure.
    ///
    /// Expensive: 12.8 ms per call at 1 Hz, the single largest cost in a tick
    /// before it was moved to `purgeableEvery`. The OS computes it by asking
    /// what could be reclaimed, which is not something to do every second.
    private func purgeableGB(free: Double) -> Double {
        guard let v = try? URL(fileURLWithPath: "/System/Volumes/Data")
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let important = v.volumeAvailableCapacityForImportantUsage else { return 0 }
        return max(Double(important) / 1e9 - free, 0)
    }

    /// Cumulative bytes read/written across block storage drivers.
    private func diskBytes() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0, write: UInt64 = 0
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iter) }
        while case let drive = IOIteratorNext(iter), drive != 0 {
            defer { IOObjectRelease(drive) }
            guard let props = IORegistryEntryCreateCFProperty(
                    drive, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            read  += (props["Bytes (Read)"]  as? NSNumber)?.uint64Value ?? 0
            write += (props["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }

    private func swapfileCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/System/Volumes/VM"))?
            .filter { $0.hasPrefix("swapfile") }.count ?? 0
    }

    // MARK: - network

    /// Non-loopback byte counters, **low 32 bits only** -- see below.
    ///
    /// One sysctl walks every interface the kernel knows about, which keeps
    /// this consistent with the rest of the file: no fork, no per-interface
    /// bookkeeping, no netstat.
    ///
    /// The truncation is not a shortcut, it is the kernel's. `if_data64`
    /// declares `ifi_ibytes` as 64-bit and Swift imports it as such, but the
    /// RTM_IFINFO2 message only ever populates the low 32 bits: verified by
    /// scanning all 180 bytes of en0's message for netstat's 39.7 GB figure
    /// and finding it nowhere. (The message is 180 bytes; Swift's imported
    /// `if_msghdr2` is 160, so the header is stale against this kernel too --
    /// another reason not to trust the declared width.)
    ///
    /// Returning the truncated sum is nonetheless *exact* for this tool's
    /// purposes, because rates are all it wants. Truncation is reduction mod
    /// 2^32, addition commutes with it, and so does subtraction: the wrapped
    /// difference of the wrapped sums equals the true delta whenever the true
    /// delta is under 4 GiB. At 1 Hz that bound is 34 Gb/s, which no interface
    /// on this machine can reach. Summing first and masking once is therefore
    /// safe; what is *not* safe is widening these to UInt64 and subtracting,
    /// which turns one interface's wrap into a 4-billion-byte spike.
    private func netBytes() -> (inB: UInt32, outB: UInt32) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var inB: UInt64 = 0, outB: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var off = 0
            // The buffer is a packed sequence of variable-length messages, so
            // a header is not guaranteed to land on its natural alignment.
            // loadUnaligned, not load -- the latter traps here on arm64.
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                let msglen = Int(hdr.ifm_msglen)
                guard msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2,
                   hdr.ifm_flags & Int32(IFF_LOOPBACK) == 0,
                   off + MemoryLayout<if_msghdr2>.size <= len {
                    let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    inB &+= m.ifm_data.ifi_ibytes
                    outB &+= m.ifm_data.ifi_obytes
                }
                off += msglen
            }
        }
        return (UInt32(truncatingIfNeeded: inB), UInt32(truncatingIfNeeded: outB))
    }

    // MARK: - power

    private func battery() -> (pct: Int, charging: Bool, ac: Bool, mins: Int?,
                               health: Double, cycles: Int) {
        var pct = 0, charging = false, ac = false, mins: Int? = nil
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let d = IOPSGetPowerSourceDescription(blob, src)?
                        .takeUnretainedValue() as? [String: Any] else { continue }
                let cur = d[kIOPSCurrentCapacityKey as String] as? Int ?? 0
                let max = d[kIOPSMaxCapacityKey as String] as? Int ?? 100
                pct = max > 0 ? Int(Double(cur) / Double(max) * 100) : 0
                charging = d[kIOPSIsChargingKey as String] as? Bool ?? false
                ac = (d[kIOPSPowerSourceStateKey as String] as? String) == kIOPSACPowerValue
                if let m = d[kIOPSTimeToEmptyKey as String] as? Int, m > 0 { mins = m }
                if charging, let m = d[kIOPSTimeToFullChargeKey as String] as? Int, m > 0 { mins = m }
            }
        }
        // Health and cycles are static-ish; read from the SMC battery node.
        var health = 0.0, cycles = 0
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            func num(_ k: String) -> Double? {
                (IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber)?.doubleValue
            }
            // Capacities live inside the BatteryData sub-dictionary, not at the
            // top level. Do NOT fall back to the top-level "MaxCapacity": that
            // one is a percentage (100), so pairing it with DesignCapacity in
            // mAh yields a confident, plausible, completely wrong 1.96%.
            let data = IORegistryEntryCreateCFProperty(svc, "BatteryData" as CFString,
                                                       kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            func cap(_ k: String) -> Double? { (data?[k] as? NSNumber)?.doubleValue }
            // Nominal vs design, matching the convention Auscult reports, so the
            // two tools never disagree about the same cell.
            if let design = cap("DesignCapacity"), design > 0,
               let nominal = cap("NominalChargeCapacity") ?? cap("FullChargeCapacity") {
                health = nominal / design * 100
            }
            cycles = Int(num("CycleCount") ?? cap("CycleCount") ?? 0)
        }
        return (pct, charging, ac, mins, health, cycles)
    }

    // MARK: - processes (sampled sparsely; ps is a fork)

    /// One `ps` every 5 ticks, sorted twice in-process.
    ///
    /// This used to pass `-r` and let ps do the ordering, which meant a
    /// memory-ordered list would have cost a second fork -- and the fork
    /// budget is the whole reason the rest of this file talks to Mach
    /// directly. Parsing the full table and sorting it twice here keeps that
    /// budget exactly where it was. ~700 rows costs microseconds; a fork does
    /// not.
    /// Top processes by CPU and by memory, read natively with libproc.
    ///
    /// This used to fork /bin/ps every fifth tick: ~4 ms in the daemon plus
    /// ~46 ms in each ps it spawned, so roughly 10 ms of machine CPU per second
    /// that never showed in the daemon's own figure. proc_pidinfo reads the
    /// same numbers without a process. CPU% is the change in CPU time between
    /// sweeps over wall time -- a true average over the interval, unlike ps's
    /// kernel-decayed %cpu.
    private mutating func topProcesses(now: Double) -> (cpu: [ProcessSample], mem: [ProcessSample], count: Int) {
        // Tick 1 takes the baseline, tick 2 is the first with real CPU%.
        guard tick <= 2 || tick % 5 == 0 else { return (cachedCPU, cachedMem, cachedProcCount) }

        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return (cachedCPU, cachedMem, cachedProcCount) }
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = Int(pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) })
        guard n > 0 else { return (cachedCPU, cachedMem, cachedProcCount) }

        let dtNs = prevProcStamp > 0 ? (now - prevProcStamp) * 1e9 : 0
        var cpuNow: [pid_t: UInt64] = [:]
        cpuNow.reserveCapacity(n)
        var rows: [(pid: pid_t, cpu: Double, rss: UInt64)] = []
        rows.reserveCapacity(n)
        let tiSize = Int32(MemoryLayout<proc_taskinfo>.size)
        for pid in pids.prefix(n) {
            var ti = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tiSize) == tiSize else { continue }
            let t = ti.pti_total_user + ti.pti_total_system
            cpuNow[pid] = t
            var pct = 0.0
            if dtNs > 0, let prev = prevProcCPU[pid], t >= prev {
                pct = Double(t - prev) * nsPerMach / dtNs * 100
            }
            rows.append((pid, pct, ti.pti_resident_size))
        }
        prevProcCPU = cpuNow            // also drops processes that exited
        prevProcStamp = now

        // Names only for the handful actually shown, not all ~700 processes.
        func name(_ pid: pid_t) -> String {
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                return (String(cString: path) as NSString).lastPathComponent
            }
            var short = [CChar](repeating: 0, count: 64)
            if proc_name(pid, &short, UInt32(short.count)) > 0 { return String(cString: short) }
            return "pid \(pid)"
        }
        func sample(_ r: (pid: pid_t, cpu: Double, rss: UInt64)) -> ProcessSample {
            ProcessSample(pid: Int(r.pid), name: name(r.pid), cpuPct: r.cpu, rssMB: Double(r.rss) / 1_048_576)
        }
        cachedCPU = rows.sorted { $0.cpu > $1.cpu }.prefix(8).map(sample)
        cachedMem = rows.sorted { $0.rss > $1.rss }.prefix(8).map(sample)
        cachedProcCount = rows.count
        return (cachedCPU, cachedMem, cachedProcCount)
    }

    // MARK: - host description

    func hostInfo() -> HostInfo {
        HostInfo(
            model: sysctlString("hw.model") ?? "Mac",
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            pCoreCount: sysctlInt("hw.perflevel0.physicalcpu") ?? 0,
            eCoreCount: sysctlInt("hw.perflevel1.physicalcpu") ?? 0,
            // No sysctl exposes the DVFS ceiling; these are the M2's published
            // maxima and only scale the gauges.
            pCoreMaxMHz: 3504,
            eCoreMaxMHz: 2424,
            // GiB, not GB. hw.memsize is 8589934592 -- decimal division gives
            // 8.59, which rounds to a "9 GB" machine that Apple never sold.
            memoryGB: Double(sysctlInt("hw.memsize") ?? 0) / 1_073_741_824
        )
    }

    // MARK: - one tick

    /// Fill in everything except the powermetrics fields, which the caller merges.
    mutating func sample(into s: inout Sample) {
        tick += 1
        let now = Date().timeIntervalSince1970
        let dt = max(now - prevStamp, 0.001)

        if let vm = vmStats() {
            let ps = pageSize
            let mb = { (pages: UInt64) in Double(pages) * ps / 1_048_576 }
            s.wiredMB = mb(UInt64(vm.wire_count))
            s.compressedMB = mb(UInt64(vm.compressor_page_count))
            s.appMB = mb(UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count))
            s.cachedMB = mb(UInt64(vm.external_page_count))

            if let p = prevVM {
                func rate(_ a: UInt64, _ b: UInt64) -> Double {
                    a >= b ? Double(a - b) / dt : 0
                }
                s.swapInPagesPerSec = rate(vm.swapins, p.swapins)
                s.swapOutPagesPerSec = rate(vm.swapouts, p.swapouts)
                s.compressionsPerSec = rate(vm.compressions, p.compressions)
                s.decompressionsPerSec = rate(vm.decompressions, p.decompressions)
            }
            prevVM = vm
        }
        s.thrashRatio = s.swapOutPagesPerSec > 0
            ? min(s.swapInPagesPerSec / s.swapOutPagesPerSec, 2.0) : 0

        s.memFreePct = sysctlInt("kern.memorystatus_level") ?? 0
        let swap = swapUsage()
        s.swapTotalMB = swap.total
        s.swapUsedMB = swap.used
        s.swapoutThrottled = sysctlInt("vm.compressor_swapper_swapout_fileq_throttled") ?? 0
        if due(Self.slowEvery) { cachedSwapfiles = swapfileCount() }
        s.swapfileCount = cachedSwapfiles

        let disk = diskSpace()
        s.diskFreeGB = disk.free
        s.diskTotalGB = disk.total
        if due(Self.purgeableEvery) { cachedPurgeableGB = purgeableGB(free: disk.free) }
        s.diskPurgeableGB = cachedPurgeableGB
        let io = diskBytes()
        if prevDiskRead > 0 {
            s.diskReadMBs = Double(io.read &- prevDiskRead) / 1_048_576 / dt
            s.diskWriteMBs = Double(io.write &- prevDiskWrite) / 1_048_576 / dt
        }
        prevDiskRead = io.read; prevDiskWrite = io.write

        let net = netBytes()
        // Counters are cumulative since boot, so the first tick has no
        // baseline to subtract and must report nothing rather than "several
        // gigabytes per second". A flag rather than a zero check: zero is a
        // legitimate reading on a machine that has not used the network yet.
        if hasNetBaseline {
            // &- on UInt32 is the wraparound subtraction the comment on
            // netBytes() relies on. Do not widen these operands.
            s.netInBps = Double(net.inB &- prevNetIn) / dt
            s.netOutBps = Double(net.outB &- prevNetOut) / dt
        }
        prevNetIn = net.inB; prevNetOut = net.outB
        hasNetBaseline = true

        if due(Self.slowEvery) || cachedBattery == nil { cachedBattery = battery() }
        let b = cachedBattery!
        s.batteryPct = b.pct; s.batteryCharging = b.charging; s.batteryOnAC = b.ac
        s.batteryMinutesRemaining = b.mins
        s.batteryHealthPct = b.health; s.batteryCycles = b.cycles

        // Headline sensors every tick, the full 38-sensor sweep every
        // slowEvery; see Thermal.reading(full:).
        if let r = thermal?.reading(full: due(Self.slowEvery)) {
            s.dieTempC = r.die; s.pmu2TempC = r.pmu2
            s.nandTempC = r.nand; s.batteryTempC = r.battery
            s.sensorCount = r.sensorCount
            s.topSensors = r.sensors.prefix(6).map { TempSensor(name: $0.name, celsius: $0.celsius) }
        }
        s.fans = fans?.reading() ?? []

        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        s.load1 = la[0]; s.load5 = la[1]; s.load15 = la[2]
        // kern.num_tasks is the task LIMIT (2048 here, 696 actually running),
        // which is what this field showed until the process sweep below could
        // supply a real count for free.
        let procs = topProcesses(now: now)
        s.topCPU = procs.cpu
        s.topMem = procs.mem
        s.processCount = procs.count

        prevStamp = now
    }
}
