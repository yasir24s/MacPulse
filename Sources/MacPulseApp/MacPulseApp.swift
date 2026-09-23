import SwiftUI
import MacPulseCore

/// What the menu bar itself shows next to the icon.
///
/// Deliberately one number at a time. The menu bar is the only surface that
/// is always visible, and a row of four competing figures there is one you
/// stop reading within a day -- which is the same as showing nothing, but
/// wider.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case icon, memory, swap, thrash, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: return "Icon only"
        case .memory: return "Memory free"
        case .swap: return "Swap used"
        case .thrash: return "Thrash ratio"
        case .network: return "Network down"
        }
    }

    func readout(_ s: Sample) -> String? {
        switch self {
        case .icon: return nil
        case .memory: return "\(s.memFreePct)%"
        case .swap: return Fmt.mb(s.swapUsedMB)
        case .thrash: return String(format: "%.2f", s.thrashRatio)
        case .network: return Fmt.bps(s.netInBps)
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var client: Client
    @AppStorage("menuBarMetric") private var metricRaw = MenuBarMetric.icon.rawValue

    private var metric: MenuBarMetric { MenuBarMetric(rawValue: metricRaw) ?? .icon }

    var body: some View {
        HStack(spacing: 3) {
            // Template image so AppKit tints it for light/dark menu bars and
            // inverts it on highlight. A coloured PNG would look wrong in half
            // the cases and broken when the menu is open.
            if let url = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                let _ = img.isTemplate = true
                Image(nsImage: img)
            } else {
                Image(systemName: "chart.bar.fill")
            }
            if let s = client.latest, let text = metric.readout(s) {
                // Monospaced digits: without them the whole menu bar shuffles
                // sideways every time a digit changes width.
                Text(text).font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
    }
}

@main
struct MacPulseApp: App {
    @StateObject private var client = Client()

    var body: some Scene {
        MenuBarExtra {
            Panel(client: client)
                .task { client.start() }
        } label: {
            MenuBarLabel(client: client)
        }
        .menuBarExtraStyle(.window)
    }
}
