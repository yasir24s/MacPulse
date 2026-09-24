import Charts
import SwiftUI
import MacPulseCore

/// The dropdown. Ordered by what actually constrains this class of machine:
/// swap first, then memory, then storage -- CPU and thermals sit lower because
/// on an 8 GB Apple Silicon laptop they are almost never the binding limit.
struct Panel: View {
    @ObservedObject var client: Client
    @AppStorage("menuBarMetric") private var menuBarMetric = MenuBarMetric.icon.rawValue

    private var s: Sample? { client.latest }
    private var series: [Sample] { client.samples }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                DaemonBanner(client: client)
                alertBanner
                if let s {
                    thermalCard(s)
                    swapCard(s)
                    memoryCard(s)
                    memoryProcessCard(s)
                    storageCard(s)
                    networkCard(s)
                    cpuCard(s)
                    socCard(s)
                    powerCard(s)
                    processCard(s)
                } else {
                    waiting
                }
                footer
            }
            .padding(10)
        }
        .frame(width: 340, height: 620)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(client.host?.chip ?? "MacPulse")
                    .font(.system(size: 13, weight: .semibold))
                if let h = client.host {
                    Text("\(h.pCoreCount)P + \(h.eCoreCount)E · \(String(format: "%.0f", h.memoryGB)) GB")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let p = s?.thermalPressure {
                Text(p)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(p == "Nominal" ? Color.green.opacity(0.18) : Color.orange.opacity(0.22),
                                in: Capsule())
                    .foregroundStyle(p == "Nominal" ? .green : .orange)
            }
            Circle()
                .fill(client.connected ? Color.green : Color.red)
                .frame(width: 7, height: 7)
        }
    }

    /// Firing alerts, above everything. Shown even while the rest of the
    /// panel is still waiting for a first sample.
    @ViewBuilder private var alertBanner: some View {
        ForEach(client.alerts) { a in
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: a.severity == .critical
                      ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                    .font(.system(size: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title).font(.system(size: 11, weight: .semibold))
                    Text(a.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(a.severity == .critical ? Color.red : Color.orange)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((a.severity == .critical ? Color.red : Color.orange).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(client.protocolMismatch
                 ? "Daemon is older than this app"
                 : client.connected ? "Waiting for first sample…" : "Daemon not running")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(client.protocolMismatch ? .orange : .primary)
            if client.protocolMismatch {
                Text("It is connected but sending frames this build cannot read. Use Update daemon above.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: thermal

    private func thermalCard(_ s: Sample) -> some View {
        SectionCard(title: "Thermal", accent: .red) {
            if let die = s.dieTempC {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.1f°C", die))
                        .font(.system(size: 20, weight: .semibold).monospacedDigit())
                        .foregroundStyle(die >= 95 ? .red : die >= 80 ? .orange : .primary)
                    Text(String(format: "%.0f°F", die * 9 / 5 + 32))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("SoC die").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Sparkline(values: series.compactMap(\.dieTempC), tint: .red, ceiling: 110)
                if let n = s.nandTempC { Row(label: "SSD", value: String(format: "%.1f°C", n)) }
                if let b = s.batteryTempC { Row(label: "battery", value: String(format: "%.1f°C", b)) }
                Row(label: "sensors", value: "\(s.sensorCount)")
                // This Mac names no CPU/GPU/ANE sensor; show the raw hardware
                // names rather than inventing labels it never reported.
                ForEach(s.topSensors.prefix(3), id: \.name) { t in
                    HStack {
                        Text(t.name).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(String(format: "%.1f°C", t.celsius))
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("no sensor access — IOHID symbols unavailable")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            // Fans come from SMC keys, not IOHID, so they are readable even
            // when the temperature path above is not -- hence outside that
            // branch rather than inside it.
            ForEach(s.fans, id: \.index) { f in
                Divider().opacity(0.4)
                FanControlView(client: client, fan: f)
                    .padding(.bottom, 2)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(String(format: "%.0f rpm", f.rpm))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(f.fraction >= 0.95 ? .red
                                         : f.fraction >= 0.70 ? .orange : .primary)
                    Text(String(format: "%.0f%%", f.fraction * 100))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Text(s.fans.count > 1 ? "fan \(f.index)" : "fan")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                // Scaled against the SMC's own floor and ceiling: a raw RPM
                // figure says nothing on its own, since 7,200 is flat out on
                // this machine and unremarkable on a Mac Pro.
                FillBar(fraction: f.fraction, warn: 0.70, crit: 0.95)
                Row(label: "range", value: String(format: "%.0f – %.0f rpm", f.minRPM, f.maxRPM))
            }
            if let f = s.fans.first, s.fans.count == 1 {
                Sparkline(values: series.compactMap { $0.fans.first?.rpm },
                          tint: .red, ceiling: f.maxRPM)
            }
        }
    }

    // MARK: swap

    private func swapCard(_ s: Sample) -> some View {
        SectionCard(title: "Swap", accent: .orange) {
            FillBar(fraction: s.swapTotalMB > 0 ? s.swapUsedMB / s.swapTotalMB : 0)
            Row(label: "used", value: "\(Fmt.mb(s.swapUsedMB)) of \(Fmt.mb(s.swapTotalMB))")
            Row(label: "swapfiles", value: "\(s.swapfileCount)")

            DualSparkline(a: series.map(\.swapInPagesPerSec),
                          b: series.map(\.swapOutPagesPerSec))
            HStack(spacing: 10) {
                Label(Fmt.rate(s.swapInPagesPerSec), systemImage: "arrow.down")
                    .foregroundStyle(.orange)
                Label(Fmt.rate(s.swapOutPagesPerSec), systemImage: "arrow.up")
                    .foregroundStyle(.purple)
            }
            .font(.system(size: 10, weight: .medium).monospacedDigit())

            // Ratio near 1.0 = pages evicted then immediately faulted back.
            // That distinction is the whole point of the card.
            Row(label: "thrash ratio",
                value: String(format: "%.2f", s.thrashRatio),
                tint: s.thrashRatio > 0.8 ? .red : s.thrashRatio > 0.5 ? .orange : .secondary)
            Row(label: "swapouts throttled",
                value: "\(s.swapoutThrottled)",
                tint: s.swapoutThrottled > 0 ? .orange : .secondary)
        }
    }

    // MARK: memory

    private func memoryCard(_ s: Sample) -> some View {
        SectionCard(title: "Memory", accent: .blue) {
            Row(label: "free", value: "\(s.memFreePct)%",
                tint: s.memFreePct < 15 ? .red : s.memFreePct < 30 ? .orange : .primary)
            Sparkline(values: series.map { Double($0.memFreePct) },
                      tint: .blue, ceiling: 100)
            Row(label: "app", value: Fmt.mb(s.appMB))
            Row(label: "wired", value: Fmt.mb(s.wiredMB))
            Row(label: "compressed", value: Fmt.mb(s.compressedMB))
            Row(label: "cached files", value: Fmt.mb(s.cachedMB))
            Row(label: "compressor", value: "\(Fmt.rate(s.compressionsPerSec)) in · \(Fmt.rate(s.decompressionsPerSec)) out")
        }
    }

    // MARK: storage

    private func storageCard(_ s: Sample) -> some View {
        SectionCard(title: "Storage", accent: .teal) {
            let usedFrac = s.diskTotalGB > 0 ? 1 - (s.diskFreeGB / s.diskTotalGB) : 0
            FillBar(fraction: usedFrac, warn: 0.85, crit: 0.93)
            Row(label: "free", value: "\(Fmt.gb(s.diskFreeGB)) of \(Fmt.gb(s.diskTotalGB))",
                tint: s.diskFreeGB < 15 ? .red : s.diskFreeGB < 40 ? .orange : .primary)
            if s.diskPurgeableGB > 0.5 {
                Row(label: "purgeable", value: "+ \(Fmt.gb(s.diskPurgeableGB))", tint: .secondary)
                Row(label: "Finder shows",
                    value: Fmt.gb(s.diskFreeGB + s.diskPurgeableGB), tint: .secondary)
                ReclaimView(purgeableGB: s.diskPurgeableGB)
            }
            Row(label: "read", value: Fmt.mbs(s.diskReadMBs))
            Row(label: "write", value: Fmt.mbs(s.diskWriteMBs))
            Sparkline(values: series.map { $0.diskReadMBs + $0.diskWriteMBs }, tint: .teal)
        }
    }

    // MARK: network

    private func networkCard(_ s: Sample) -> some View {
        SectionCard(title: "Network", accent: .cyan) {
            Row(label: "down", value: Fmt.bps(s.netInBps))
            Row(label: "up", value: Fmt.bps(s.netOutBps))
            // Same shape as the swap card on purpose: two series on one axis,
            // where the relationship between them is the thing worth seeing.
            DualSparkline(a: series.map(\.netInBps), b: series.map(\.netOutBps),
                          aTint: .cyan, bTint: .mint)
            Text("excludes loopback")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    // MARK: cpu

    private func cpuCard(_ s: Sample) -> some View {
        SectionCard(title: "CPU", accent: .indigo) {
            Row(label: "P-cluster", value: Fmt.mhz(s.pClusterMHz))
            Sparkline(values: series.map { Double($0.pClusterMHz) },
                      tint: .indigo, filled: false,
                      ceiling: Double(client.host?.pCoreMaxMHz ?? 3504))
            Row(label: "E-cluster", value: Fmt.mhz(s.eClusterMHz))
            Row(label: "package", value: Fmt.watts(s.cpuPowerMW))
            Row(label: "load", value: String(format: "%.2f · %.2f · %.2f", s.load1, s.load5, s.load15))
            Row(label: "processes", value: "\(s.processCount)")
        }
    }

    // MARK: soc

    private func socCard(_ s: Sample) -> some View {
        SectionCard(title: "GPU / Neural Engine", accent: .pink) {
            Row(label: "GPU", value: Fmt.watts(s.gpuPowerMW))
            Row(label: "ANE", value: Fmt.watts(s.anePowerMW),
                tint: s.anePowerMW > 0 ? .pink : .secondary)
            if series.contains(where: { $0.anePowerMW > 0 }) {
                Sparkline(values: series.map { Double($0.anePowerMW) }, tint: .pink)
            }
            if s.anePowerMW == 0 {
                // Relevant to on-device inference work: a flat zero here while
                // a model is running means it is not on the Neural Engine.
                Text("idle — no Neural Engine activity")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: power

    private func powerCard(_ s: Sample) -> some View {
        SectionCard(title: "Power", accent: .green) {
            FillBar(fraction: Double(s.batteryPct) / 100,
                    tint: s.batteryPct < 15 ? .red : s.batteryPct < 30 ? .orange : .green)
            HStack {
                Text("\(s.batteryPct)%")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(s.batteryPct < 15 ? .red : .primary)
                Text(s.batteryOnAC ? (s.batteryCharging ? "charging" : "on AC") : "on battery")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if let m = s.batteryMinutesRemaining {
                    Text("\(m / 60)h \(m % 60)m").font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Row(label: "health", value: String(format: "%.1f%%", s.batteryHealthPct))
            Row(label: "cycles", value: "\(s.batteryCycles)")
        }
    }

    // MARK: processes

    /// Sits directly under the memory card, because on 8 GB "what is eating
    /// it" is the immediate next question and the CPU list almost never
    /// answers it.
    private func memoryProcessCard(_ s: Sample) -> some View {
        SectionCard(title: "Top by memory", accent: .blue) {
            if s.topMem.isEmpty {
                Text("sampling…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(s.topMem.prefix(5), id: \.pid) { p in
                HStack {
                    Text(p.name).font(.system(size: 10)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(Fmt.mb(p.rssMB))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(isLargeShare(p.rssMB) ? .orange : .primary)
                    Text(String(format: "%.0f%%", p.cpuPct))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    /// True when one process holds more than a quarter of physical memory.
    /// Not a verdict -- just the threshold at which a single name is worth
    /// looking at twice on a machine this size.
    private func isLargeShare(_ rssMB: Double) -> Bool {
        guard let gb = client.host?.memoryGB, gb > 0 else { return false }
        return rssMB > gb * 1024 * 0.25
    }

    private func processCard(_ s: Sample) -> some View {
        SectionCard(title: "Top by CPU", accent: .secondary) {
            if s.topCPU.isEmpty {
                Text("sampling…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(s.topCPU.prefix(5), id: \.pid) { p in
                HStack {
                    Text(p.name).font(.system(size: 10)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(String(format: "%.0f%%", p.cpuPct))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(p.cpuPct > 90 ? .red : .primary)
                    Text(Fmt.mb(p.rssMB))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("menu bar").font(.system(size: 9)).foregroundStyle(.secondary)
                Picker("", selection: $menuBarMetric) {
                    ForEach(MenuBarMetric.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .controlSize(.mini)
            }
            HStack {
                if let first = series.first, let last = series.last {
                    Text("\(Int(last.t - first.t))s window · \(series.count) samples")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
