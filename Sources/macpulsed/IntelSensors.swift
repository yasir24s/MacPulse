import Darwin
import Foundation

/// Which kind of Mac this is, decided from the hardware at runtime.
///
/// Not `#if arch(x86_64)`: the release is universal, and its x86_64 slice can
/// run under Rosetta on an Apple Silicon Mac, where every Apple Silicon path
/// (cluster frequencies, ANE rail, IOHID sensors) is still the right one.
/// `hw.optional.arm64` reports the hardware even to a translated process.
enum Platform {
    static let isAppleSilicon: Bool = {
        var v: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &size, nil, 0) == 0 && v == 1
    }()

    /// powermetrics samplers this machine supports. An unsupported name makes
    /// powermetrics exit at once ("unrecognized sampler"), which the watchdog
    /// would turn into a restart loop with no data, so the lists are separate:
    /// Intel has no `ane_power`, and Apple Silicon has no `smc`. On Intel, `smc`
    /// is where die temperature comes from.
    static var powermetricsSamplers: String {
        isAppleSilicon ? "cpu_power,gpu_power,ane_power,thermal"
                       : "cpu_power,gpu_power,thermal,smc"
    }
}

/// Parsing for the Intel forms of powermetrics' lines. Confirmed on Intel:
/// `CPU die temperature: <n> C` (smc) and `Current pressure level` (thermal).
/// Power and frequency wording varies between macOS releases and has not been
/// checked against a real Intel Mac, so those match loosely: any "package
/// power" line, any "average frequency" line carrying a "(<n> Mhz)" figure.
enum IntelLines {
    /// First decimal number in the line after `marker`.
    static func number(after marker: String, in line: String) -> Double? {
        guard let r = line.range(of: marker, options: .caseInsensitive) else { return nil }
        var digits = ""
        for c in line[r.upperBound...] {
            if c.isNumber || (c == "." && !digits.contains(".") && !digits.isEmpty) { digits.append(c) }
            else if !digits.isEmpty { break }
        }
        return Double(digits)
    }

    static func dieTempC(_ line: String) -> Double? {
        line.localizedCaseInsensitiveContains("CPU die temperature")
            ? number(after: "temperature:", in: line) : nil
    }

    /// Milliwatts. Intel prints watts ("...: 1.95W"); a line in mW is taken as is.
    static func packageMW(_ line: String) -> Int? {
        guard line.localizedCaseInsensitiveContains("package power"),
              let v = number(after: ":", in: line) else { return nil }
        return line.localizedCaseInsensitiveContains("mW") ? Int(v) : Int((v * 1000).rounded())
    }

    static func averageMHz(_ line: String) -> Int? {
        guard line.localizedCaseInsensitiveContains("average frequency"),
              let v = number(after: "(", in: line),
              line.localizedCaseInsensitiveContains("mhz") else { return nil }
        return Int(v.rounded())
    }
}
