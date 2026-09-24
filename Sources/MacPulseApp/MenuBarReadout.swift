import AppKit
import SwiftUI
import MacPulseCore

/// Two-line menu bar readout, the layout Macs Fan Control used:
///
///     58.9°C
///     4470rpm
///
/// A MenuBarExtra label is flattened into the status item's title and image,
/// and SwiftUI does not reliably carry a VStack through that -- the second
/// line gets dropped or the layout collapses to one baseline. So the stack is
/// rendered to an image each tick instead. Marked as a template, which is what
/// lets AppKit tint it for light and dark menu bars and invert it while the
/// menu is open, exactly as it does for the icon beside it.
enum MenuBarReadout {

    /// Menu bar is ~22 pt tall; two 9 pt lines with the leading squeezed out
    /// fit with a hair to spare, which is the same budget MFC worked within.
    private struct Stack: View {
        let top: String
        let bottom: String
        var body: some View {
            VStack(alignment: .trailing, spacing: -2) {
                Text(top).font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                Text(bottom).font(.system(size: 9, weight: .regular).monospacedDigit())
            }
            // A floor on width so the item does not jump sideways when the
            // fan crosses 999 -> 1000 rpm. Monospaced digits fix digit width;
            // they cannot fix a digit appearing.
            .frame(minWidth: 38, alignment: .trailing)
            // Pure black: a template image uses only alpha, and AppKit
            // supplies the colour.
            .foregroundStyle(.black)
        }
    }

    /// Icon and stack drawn as ONE image. A MenuBarExtra label keeps a single
    /// image: an Image for the icon plus a second Image for the stack showed
    /// only the icon -- the readout silently vanished, while a Text beside the
    /// same icon rendered fine. So the icon is composited in here and the
    /// label shows this image alone.
    private struct Composite: View {
        let icon: NSImage?
        let top: String
        let bottom: String
        var body: some View {
            HStack(spacing: 3) {
                if let icon {
                    Image(nsImage: icon).renderingMode(.template)
                        .resizable().frame(width: 18, height: 18)
                }
                Stack(top: top, bottom: bottom)
            }
            .foregroundStyle(.black)
        }
    }

    /// Main-actor only because ImageRenderer is; the formatters below are
    /// pure and callable from anywhere.
    @MainActor
    static func image(icon: NSImage?, top: String, bottom: String) -> NSImage? {
        let r = ImageRenderer(content: Composite(icon: icon, top: top, bottom: bottom))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = r.nsImage else { return nil }
        img.isTemplate = true
        return img
    }

    static func temperature(_ s: Sample) -> String? {
        s.dieTempC.map { String(format: "%.1f°C", $0) }
    }

    /// nil on a fanless Mac. Deliberately not "0rpm": on a fan readout zero
    /// means "stopped", which is a specific claim, not "there is no fan".
    static func fanSpeed(_ s: Sample) -> String? {
        s.fans.first.map { String(format: "%.0frpm", $0.rpm) }
    }
}
