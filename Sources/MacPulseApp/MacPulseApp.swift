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
    @ObservedObject var model: MenuBarModel

    /// Loaded once. It used to be re-read from the bundle on every redraw.
    private static let icon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarTemplate", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }()

    @ViewBuilder private var iconView: some View {
        // Template image so AppKit tints it for light/dark menu bars and
        // inverts it on highlight. A coloured PNG would look wrong in half
        // the cases and broken when the menu is open.
        if let icon = Self.icon { Image(nsImage: icon) } else { Image(systemName: "chart.bar.fill") }
    }

    var body: some View {
        switch model.display {
        case .stacked(let top, let bottom):
            // The label may hold only ONE image, so icon and both lines arrive
            // pre-composited and nothing else is drawn.
            if let img = MenuBarReadout.image(icon: Self.icon, top: top, bottom: bottom) {
                Image(nsImage: img)
            } else {
                iconView
            }
        case .text(let text):
            HStack(spacing: 3) {
                iconView
                // Monospaced digits: without them the whole menu bar shuffles
                // sideways every time a digit changes width.
                Text(text).font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        case .icon:
            iconView
        }
    }
}

@main
struct MacPulseApp: App {
    // @State, not @StateObject: the App must HOLD the client without
    // OBSERVING it. As a @StateObject every publish (samples, once a second at
    // least) invalidated the whole scene -- AppGraph.graphDidChange in the
    // profile -- so SwiftUI re-applied the label to the status item even when
    // it had not changed, and AppKit re-captured a bitmap of it for every menu
    // bar replicant (NSStatusItem _updateReplicants). "Icon only" cost nearly
    // as much as a live readout for that reason. The panel and the label each
    // observe exactly what they draw.
    @State private var client = Client()

    var body: some Scene {
        MenuBarExtra {
            // No .task { client.start() } here: the client starts itself at
            // init, because this content does not exist until the first click.
            Panel(client: client)
        } label: {
            MenuBarLabel(model: client.menuBar)
        }
        .menuBarExtraStyle(.window)
    }
}
