import CryptoKit
import Foundation
import SwiftUI

/// Installs or updates the root daemon from the app, behind the standard
/// macOS administrator-password dialog.
///
/// The installer and the helper binary both live inside this app's bundle, so
/// what gets installed is always the daemon built alongside the running app --
/// the two cannot drift. The mechanism is the same as snapshot reclaim:
/// `do shell script ... with administrator privileges`, which prompts on every
/// use and leaves no standing privilege behind. SMAppService was not an option:
/// it needs a Developer ID signature this project does not have, and it asks
/// for approval once in System Settings rather than a password per install.
///
/// Trust note: the bundle lives in the user's own build directory, so anything
/// running as the user could alter the bundled script before this runs it as
/// root. That is exactly the trust level of `sudo Scripts/install-daemon.sh`
/// from the same repo; this adds no new exposure, it just removes the terminal.
enum DaemonInstaller {

    static let installedPath = "/usr/local/libexec/macpulsed"

    static var bundledHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macpulsed")
    }

    static var bundledInstaller: URL? {
        Bundle.main.url(forResource: "install-daemon", withExtension: "sh")
    }

    enum Status: Equatable {
        /// Installed daemon is byte-identical to the one in this bundle.
        case current
        /// Installed, but a different build from this app's.
        case stale
        case missing
        /// Can't tell -- e.g. running from a bundle without a helper.
        case unknown
    }

    /// Compares content hashes, not dates: install(1) stamps the copy with the
    /// time it was installed, so mtime never matches the source anyway.
    static func status() -> Status {
        guard let mine = try? Data(contentsOf: bundledHelper) else { return .unknown }
        guard let theirs = FileManager.default.contents(atPath: installedPath) else { return .missing }
        return SHA256.hash(data: mine) == SHA256.hash(data: theirs) ? .current : .stale
    }

    enum Outcome: Equatable {
        case installed(String)
        case cancelled
        case failed(String)
    }

    /// Blocks until the password dialog is dismissed and the script finishes;
    /// call off the main thread.
    static func install() -> Outcome {
        guard let script = bundledInstaller?.path else {
            return .failed("installer missing from app bundle -- rebuild with Scripts/bundle-app.sh")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // The path is passed as argv, never interpolated into AppleScript
        // source, so no character in it can break or subvert the command.
        p.arguments = [
            "-e", "on run argv",
            // Without "without altering line endings" every \n comes back as \r,
            // collapsing all output onto one line.
            "-e", "do shell script (quoted form of (item 1 of argv)) with administrator privileges without altering line endings",
            "-e", "end run",
            script,
        ]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return .failed(error.localizedDescription) }
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        if p.terminationStatus == 0 {
            let last = o.split(separator: "\n").last.map(String.init) ?? "Installed."
            return .installed(last)
        }
        // -128 is the documented "user cancelled" from the auth dialog.
        if e.contains("-128") { return .cancelled }
        return .failed(e.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// Shown only when there is something to act on: daemon missing, a different
/// build from this app, unreadable frames, or not answering at all.
struct DaemonBanner: View {
    @ObservedObject var client: Client

    @State private var status: DaemonInstaller.Status = .unknown
    @State private var busy = false
    @State private var message: String?

    private var headline: String? {
        switch status {
        case .missing: return "Daemon not installed"
        case .stale:   return "Daemon is a different build from this app"
        default:
            if client.protocolMismatch { return "Daemon is older than this app" }
            if !client.connected { return "Daemon not responding" }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Always present, zero-size. The status check below hangs off this
            // container, and SwiftUI never "appears" an empty view -- so with
            // nothing else to show, a .task on the old bare Group never ran,
            // status stayed .unknown, and the banner could never appear. The
            // check that reveals the banner must not depend on the banner.
            Color.clear.frame(width: 0, height: 0)
            if let headline {
                VStack(alignment: .leading, spacing: 5) {
                    Label(headline, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                    HStack(spacing: 6) {
                        Button(busy ? "Installing…" : (status == .missing ? "Install daemon…" : "Update daemon…")) {
                            run()
                        }
                        .disabled(busy || DaemonInstaller.bundledInstaller == nil)
                        Spacer()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Text("macOS will ask for an administrator password.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let message {
                Text(message).font(.system(size: 9)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Re-check each time the panel opens, and whenever the connection
        // drops or returns (a reinstall does both). Hashing two ~1 MB files is
        // cheap here and far too wasteful to do every tick.
        .task(id: client.connected) {
            status = await Task.detached { DaemonInstaller.status() }.value
        }
    }

    private func run() {
        busy = true
        message = nil
        Task {
            let outcome = await Task.detached { DaemonInstaller.install() }.value
            busy = false
            switch outcome {
            case .installed(let line): message = line
            case .cancelled: message = "Cancelled — nothing was changed."
            case .failed(let e): message = "Install failed: \(e)"
            }
            status = await Task.detached { DaemonInstaller.status() }.value
        }
    }
}
