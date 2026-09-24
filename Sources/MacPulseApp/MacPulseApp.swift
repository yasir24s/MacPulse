import SwiftUI
import MacPulseCore

/// What the menu bar itself shows next to the icon.
///
/// Deliberately one number at a time. The menu bar is the only surface that
/// is always visible, and a row of four competing figures there is one you
/// stop reading within a day -- which is the same as showing nothing, but
/// wider.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    case icon, memory, swap, thrash, network, temperature, fan, thermal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: return "Icon only"
        case .memory: return "Memory free"
        case .swap: return "Swap used"
        case .thrash: return "Thrash ratio"
        case .network: return "Network down"
        case .temperature: return "Temperature"
        case .fan: return "Fan speed"
        case .thermal: return "Temperature + fan"
        }
    }

    func readout(_ s: Sample) -> String? {
        switch self {
        case .icon: return nil
        case .memory: return "\(s.memFreePct)%"
        case .swap: return Fmt.mb(s.swapUsedMB)
        case .thrash: return String(format: "%.2f", s.thrashRatio)
        case .network: return Fmt.bps(s.netInBps)
        case .temperature: return MenuBarReadout.temperature(s)
        case .fan: return MenuBarReadout.fanSpeed(s)
        // Normally drawn stacked, see `stacked`. This single-line form is the
        // fallback for a fanless Mac, where there is no second line to stack.
        case .thermal: return MenuBarReadout.temperature(s)
        }
    }

    /// Two lines to stack, or nil to fall back to `readout`.
    func stacked(_ s: Sample) -> (top: String, bottom: String)? {
        guard self == .thermal,
              let t = MenuBarReadout.temperature(s),
              let f = MenuBarReadout.fanSpeed(s) else { return nil }
        return (t, f)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var client: Client
    @AppStorage("menuBarMetric") private var metricRaw = MenuBarMetric.icon.rawValue

    private var metric: MenuBarMetric { MenuBarMetric(rawValue: metricRaw) ?? .icon }

    private var icon: NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }

    var body: some View {
        // Stacked readout: the label may hold only ONE image, so icon and
        // both lines arrive pre-composited and nothing else is drawn.
        if let s = client.latest, let pair = metric.stacked(s),
           let img = MenuBarReadout.image(icon: icon, top: pair.top, bottom: pair.bottom) {
            Image(nsImage: img)
        } else {
            HStack(spacing: 3) {
                // Template image so AppKit tints it for light/dark menu bars and
                // inverts it on highlight. A coloured PNG would look wrong in half
                // the cases and broken when the menu is open.
                if let icon {
                    Image(nsImage: icon)
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
}

@main
struct MacPulseApp: App {
    @StateObject private var client = Client()

    var body: some Scene {
        MenuBarExtra {
            // No .task { client.start() } here: the client starts itself at
            // init, because this content does not exist until the first click.
            Panel(client: client)
        } label: {
            MenuBarLabel(client: client)
        }
        .menuBarExtraStyle(.window)
    }
}
