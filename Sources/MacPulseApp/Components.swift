import Charts
import SwiftUI
import MacPulseCore

/// Small reusable pieces. Kept deliberately plain: this panel is read at a
/// glance while something else is going wrong, so nothing here animates,
/// pulses, or otherwise competes with the data for attention.

struct SectionCard<Content: View>: View {
    let title: String
    var accent: Color = .secondary
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(accent)
                .tracking(0.8)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Row: View {
    let label: String
    let value: String
    var tint: Color = .primary
    var body: some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(tint)
        }
    }
}

/// Proportion bar. `warn`/`crit` are fractions at which the fill changes
/// colour -- purely visual encoding of a number the user can also read.
struct FillBar: View {
    let fraction: Double
    var warn = 0.75
    var crit = 0.90
    /// Overrides threshold tinting. Needed wherever a *low* value is the bad
    /// one (battery charge), since the thresholds here assume the opposite.
    var tint: Color? = nil

    private var fill: Color {
        if let tint { return tint }
        return fraction >= crit ? .red : fraction >= warn ? .orange : .accentColor
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(fill)
                    .frame(width: max(2, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct Sparkline: View {
    let values: [Double]
    var tint: Color = .accentColor
    var filled = true
    /// Fixed ceiling when the metric has a meaningful maximum; otherwise the
    /// line autoscales, which makes idle noise look like activity.
    var ceiling: Double?

    var body: some View {
        // A series that is entirely zero must not be drawn as a coloured line
        // across the card -- at a glance that reads as an alarm when it means
        // "nothing is happening".
        let peak = values.max() ?? 0
        let idle = peak <= 0
        let stroke: Color = idle ? .secondary.opacity(0.35) : tint
        let maxV = ceiling ?? max(peak, 0.0001)
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            LineMark(x: .value("i", i), y: .value("v", v))
                .interpolationMethod(.monotone)
                .foregroundStyle(stroke)
                .lineStyle(.init(lineWidth: idle ? 1.0 : 1.4))
            if filled && !idle {
                AreaMark(x: .value("i", i), y: .value("v", v))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(tint.opacity(0.16))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...maxV)
        .chartLegend(.hidden)
        .frame(height: 34)
    }
}

/// Two series on one axis. Used for swap in vs out, where the *relationship*
/// between the lines is the signal -- overlapping lines mean thrash.
struct DualSparkline: View {
    let a: [Double], b: [Double]
    var aTint: Color = .orange
    var bTint: Color = .purple

    var body: some View {
        let ceiling = max(a.max() ?? 1, b.max() ?? 1, 1)
        Chart {
            ForEach(Array(a.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("i", i), y: .value("v", v), series: .value("s", "in"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(aTint)
                    .lineStyle(.init(lineWidth: 1.4))
            }
            ForEach(Array(b.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("i", i), y: .value("v", v), series: .value("s", "out"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(bTint)
                    .lineStyle(.init(lineWidth: 1.4))
            }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: 0...ceiling)
        .chartLegend(.hidden)
        .frame(height: 34)
    }
}

// MARK: - formatting

enum Fmt {
    static func mb(_ v: Double) -> String {
        v >= 1024 ? String(format: "%.2f GB", v / 1024) : String(format: "%.0f MB", v)
    }
    static func gb(_ v: Double) -> String { String(format: "%.1f GB", v) }
    static func mhz(_ v: Int) -> String { "\(v) MHz" }
    static func watts(_ mw: Int) -> String {
        mw >= 1000 ? String(format: "%.2f W", Double(mw) / 1000) : "\(mw) mW"
    }
    static func rate(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.1fk/s", v / 1000) : String(format: "%.0f/s", v)
    }
    static func mbs(_ v: Double) -> String { String(format: "%.1f MB/s", v) }

    /// Network rates span six orders of magnitude between an idle machine and
    /// a download, so a fixed unit is unreadable at one end or the other.
    /// Disk keeps its fixed MB/s: it is never interestingly slow.
    static func bps(_ v: Double) -> String {
        if v >= 1_048_576 { return String(format: "%.1f MB/s", v / 1_048_576) }
        if v >= 1024 { return String(format: "%.0f KB/s", v / 1024) }
        return String(format: "%.0f B/s", v)
    }
}
