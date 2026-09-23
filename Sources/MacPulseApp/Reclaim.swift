import Foundation
import MacPulseCore

/// Snapshot reclamation, authenticated per action.
///
/// Deliberately NOT routed through the daemon. macpulsed runs as root and its
/// socket is one-directional by design; adding a command channel would mean any
/// process running as this user could trigger root deletions with no password.
/// Instead the *unprivileged* app asks macOS for authorisation each time, so
/// nothing in this project ever holds standing privilege it didn't already have.
///
/// `SMAppService` was considered and rejected: it authenticates once at
/// registration and then leaves a permanently-root helper, which is the model
/// this is trying to avoid -- and it needs a Developer ID this machine lacks.
enum Reclaim {

    struct Plan {
        var snapshots: [String]
        var purgeableGB: Double
        /// A staged macOS update's rollback point. Deleting it can leave a
        /// prepared update unable to install or revert.
        var stagedUpdatePresent: Bool
        var volume = "/System/Volumes/Data"

        var isRisky: Bool { stagedUpdatePresent }
    }

    /// What could be reclaimed, and why you might not want to.
    static func plan(purgeableGB: Double) -> Plan {
        let out = run("/usr/bin/tmutil", ["listlocalsnapshots", "/System/Volumes/Data"])
        let snaps = out.split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("com.apple") }
        return Plan(
            snapshots: snaps,
            purgeableGB: purgeableGB,
            stagedUpdatePresent: snaps.contains { $0.contains("MSUPrepareUpdate") }
        )
    }

    /// The command, verbatim, so it can be copied and run by hand instead.
    static func command(for plan: Plan, targetBytes: Int64) -> String {
        // urgency 4 = most aggressive; tmutil thins *toward* the target rather
        // than blanket-deleting, letting the OS keep what it still needs.
        "sudo tmutil thinlocalsnapshots \(plan.volume) \(targetBytes) 4"
    }

    enum Outcome {
        case reclaimed(String)
        case cancelled
        case failed(String)
    }

    /// Raises the standard macOS authentication panel. Returns .cancelled when
    /// the user dismisses it -- that is a normal outcome, not an error.
    static func perform(plan: Plan, targetBytes: Int64) -> Outcome {
        let shell = "/usr/bin/tmutil thinlocalsnapshots \(plan.volume) \(targetBytes) 4"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return .failed(error.localizedDescription) }
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        if p.terminationStatus == 0 {
            return .reclaimed(o.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        // -128 is the documented "user cancelled" code from the auth panel.
        if e.contains("-128") || e.localizedCaseInsensitiveContains("cancel") {
            return .cancelled
        }
        return .failed(e.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}
