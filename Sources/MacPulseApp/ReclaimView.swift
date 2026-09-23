import SwiftUI
import MacPulseCore

/// Reclaim controls for the Storage card.
///
/// Two-step by construction: the button reveals what will happen and why it
/// might be a bad idea *before* the auth panel appears. Destructive actions
/// behind a single click are how people delete things they meant to keep.
struct ReclaimView: View {
    let purgeableGB: Double

    @State private var plan: Reclaim.Plan?
    @State private var confirming = false
    @State private var busy = false
    @State private var message: String?
    @State private var copied = false

    private var targetBytes: Int64 { Int64(purgeableGB * 1e9) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let plan {
                if plan.snapshots.isEmpty {
                    Text("no local snapshots to reclaim")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Row(label: "snapshots", value: "\(plan.snapshots.count)")

                    if plan.stagedUpdatePresent {
                        // The whole reason this is not a one-click button.
                        Label("staged macOS update — deleting its rollback point may break the update",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if confirming {
                        Text("Thin toward \(Fmt.gb(purgeableGB))? macOS will ask for your password, and keeps whatever it still needs.")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Button(busy ? "Working…" : "Authenticate & thin") { run(plan) }
                                .disabled(busy)
                            Button("Cancel") { confirming = false }
                            Spacer()
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        HStack(spacing: 6) {
                            Button("Reclaim…") { confirming = true }
                            Button(copied ? "Copied" : "Copy command") { copy(plan) }
                            Spacer()
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if let message {
                        Text(message).font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .task { if plan == nil { plan = Reclaim.plan(purgeableGB: purgeableGB) } }
    }

    private func copy(_ plan: Reclaim.Plan) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Reclaim.command(for: plan, targetBytes: targetBytes),
                                       forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }

    private func run(_ plan: Reclaim.Plan) {
        busy = true
        // Off the main actor: the auth panel blocks until dismissed.
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Reclaim.perform(plan: plan, targetBytes: targetBytes)
            DispatchQueue.main.async {
                busy = false
                confirming = false
                switch outcome {
                case .reclaimed(let out):
                    message = out.isEmpty ? "Thinned. Free space updates on the next tick." : out
                    self.plan = Reclaim.plan(purgeableGB: purgeableGB)
                case .cancelled:
                    message = "Cancelled — nothing was deleted."
                case .failed(let e):
                    message = "Failed: \(e)"
                }
            }
        }
    }
}
