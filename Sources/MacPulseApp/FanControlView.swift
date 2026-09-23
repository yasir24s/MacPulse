import Charts
import SwiftUI
import MacPulseCore

/// Fan control. Reads state from the daemon rather than keeping its own, so
/// the UI can never claim a mode the daemon is not actually in -- including
/// when the daemon has overridden the policy itself.
struct FanControlView: View {
    @ObservedObject var client: Client
    let fan: FanSample

    private var state: ControlState? { client.control }
    private var policy: FanPolicy { state?.policy ?? FanPolicy() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let st = state {
                if st.failsafeEngaged { failsafeBanner }
                if let foreign = st.foreignController { foreignBanner(foreign) }

                Picker("", selection: Binding(
                    get: { policy.mode },
                    set: { setMode($0) }
                )) {
                    Text("Auto").tag(FanMode.auto)
                    Text("Manual").tag(FanMode.manual)
                    Text("Curve").tag(FanMode.curve)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .disabled(st.failsafeEngaged)

                switch policy.mode {
                case .auto:
                    Text("Firmware curve. MacPulse is not driving this fan.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                case .manual:
                    manualControls
                case .curve:
                    curveControls
                }

                if let e = st.lastError {
                    Text(e).font(.system(size: 9)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("no fan control available")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: banners

    private var failsafeBanner: some View {
        Label("Failsafe engaged — die above 90 °C, firmware has the fan back. "
              + "Clears at 80 °C.", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 9)).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func foreignBanner(_ who: String) -> some View {
        Label("\(who) is driving this fan. Two controllers will fight — quit it "
              + "before using Manual or Curve.", systemImage: "hand.raised.fill")
            .font(.system(size: 9)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: manual

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("\(Int(policy.manualRPM)) rpm")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                Spacer()
                Text("\(Int(fan.minRPM))–\(Int(fan.maxRPM))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { max(policy.manualRPM, fan.minRPM) },
                    set: { send(FanPolicy(mode: .manual, manualRPM: $0.rounded(),
                                          curve: policy.curve)) }
                ),
                in: fan.minRPM...fan.maxRPM
            )
            .controlSize(.small)
        }
    }

    // MARK: curve

    private var curveControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            let pts = policy.curve.isEmpty ? FanPolicy.defaultCurve : policy.curve
            Chart {
                ForEach(pts) { p in
                    LineMark(x: .value("°C", p.tempC), y: .value("rpm", p.rpm))
                        .interpolationMethod(.linear)
                        .foregroundStyle(.cyan)
                    PointMark(x: .value("°C", p.tempC), y: .value("rpm", p.rpm))
                        .foregroundStyle(.cyan)
                }
                // Where the machine actually is on that curve, right now.
                if let die = client.latest?.dieTempC {
                    RuleMark(x: .value("now", die))
                        .foregroundStyle(.orange.opacity(0.8))
                        .lineStyle(.init(lineWidth: 1, dash: [3, 2]))
                }
            }
            .chartYScale(domain: fan.minRPM...fan.maxRPM)
            .chartXScale(domain: 35...95)
            .chartXAxis { AxisMarks(values: [40, 60, 80]) { v in
                AxisValueLabel { if let t = v.as(Int.self) { Text("\(t)°").font(.system(size: 8)) } }
            } }
            .chartYAxis(.hidden)
            .frame(height: 70)

            ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 4) {
                    Text("\(Int(p.tempC))°C").font(.system(size: 9).monospacedDigit())
                        .frame(width: 38, alignment: .leading).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { p.rpm },
                            set: { v in
                                var c = pts
                                c[i] = CurvePoint(tempC: p.tempC, rpm: v.rounded())
                                send(FanPolicy(mode: .curve, manualRPM: policy.manualRPM, curve: c))
                            }
                        ),
                        in: fan.minRPM...fan.maxRPM
                    )
                    .controlSize(.mini)
                    Text("\(Int(p.rpm))").font(.system(size: 9).monospacedDigit())
                        .frame(width: 34, alignment: .trailing)
                }
            }
            Button("Reset to default curve") {
                send(FanPolicy(mode: .curve, manualRPM: policy.manualRPM,
                               curve: FanPolicy.defaultCurve))
            }
            .font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    // MARK: actions

    private func setMode(_ m: FanMode) {
        var p = policy
        p.mode = m
        // Seed sensible values the first time a mode is chosen, rather than
        // committing a zero target the daemon would clamp to the floor.
        if m == .manual && p.manualRPM < fan.minRPM { p.manualRPM = fan.minRPM }
        if m == .curve && p.curve.isEmpty { p.curve = FanPolicy.defaultCurve }
        send(p)
    }

    private func send(_ p: FanPolicy) { client.send(.setPolicy(p)) }
}
