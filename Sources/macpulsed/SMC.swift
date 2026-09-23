import Darwin
import Foundation
import IOKit
import MacPulseCore

/// Fan speeds, read from the SMC.
///
/// Unlike temperatures -- which moved off the SMC entirely on Apple Silicon
/// and live in IOHID now, see `Thermal` -- fan keys are still exactly where
/// they were on Intel: `FNum` for the count, then `F0Ac` / `F0Mn` / `F0Mx`
/// per fan. The values changed type, though: `fpe2` fixed-point on Intel,
/// IEEE `flt` here. Both are decoded, since the type comes from the key's own
/// metadata rather than being assumed.
///
/// Returns nil from `init?` on a fanless Mac (every Air) or if the SMC cannot
/// be opened, matching how `Thermal` handles an unavailable sensor path: the
/// daemon reports nothing rather than a confident zero. On a fan gauge a zero
/// reads as "stopped", which is a specific and alarming claim, not "unknown".
final class SMCFans {

    // The AppleSMC parameter block is a C struct whose Swift equivalent lays
    // out at 76 bytes where C pads it to 80. Rather than fight that with
    // padding fields -- which silently breaks again if anyone reorders them --
    // the block is built as raw bytes at explicit C offsets. Getting this
    // wrong is not a crash: every key simply reports absent, which looks
    // exactly like a Mac with no fan.
    private static let paramSize = 80
    private static let offKey = 0, offDataSize = 28, offDataType = 32
    private static let offResult = 40, offData8 = 42, offBytes = 48

    /// Selector 2 is kSMCHandleYPCEvent; data8 5 reads a key, 9 reads its info.
    private static let handleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdKeyInfo: UInt8 = 9
    /// kSMCWriteKey. Same parameter block as a read, payload filled in.
    private static let cmdWriteKey: UInt8 = 6

    private let conn: io_connect_t
    /// Index, min and max are fixed for the life of the machine, so they are
    /// read once here rather than re-read 86,400 times a day.
    private let statics: [(index: Int, min: Double, max: Double)]

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var c: io_connect_t = 0
        guard IOServiceOpen(svc, mach_task_self_, 0, &c) == kIOReturnSuccess else { return nil }
        conn = c

        guard let count = SMCFans.read(c, "FNum").flatMap(SMCFans.decode), count >= 1 else {
            IOServiceClose(c)
            return nil
        }
        statics = (0..<Int(count)).compactMap { i -> (index: Int, min: Double, max: Double)? in
            guard let mn = SMCFans.read(c, "F\(i)Mn").flatMap(SMCFans.decode),
                  let mx = SMCFans.read(c, "F\(i)Mx").flatMap(SMCFans.decode) else { return nil }
            return (i, mn, mx)
        }
        guard !statics.isEmpty else {
            IOServiceClose(c)
            return nil
        }
    }

    deinit { IOServiceClose(conn) }

    /// Current speed of every fan, plus whether something is forcing it.
    /// Mode and target are read every tick rather than cached: another tool
    /// can take the fan at any moment, and a stale "auto" would be a lie.
    func reading() -> [FanSample] {
        statics.compactMap { f in
            guard let rpm = SMCFans.read(conn, "F\(f.index)Ac").flatMap(SMCFans.decode) else { return nil }
            let mode = SMCFans.read(conn, "F\(f.index)Md").flatMap(SMCFans.decode) ?? 0
            let tgt = SMCFans.read(conn, "F\(f.index)Tg").flatMap(SMCFans.decode) ?? 0
            return FanSample(index: f.index, rpm: rpm, minRPM: f.min, maxRPM: f.max,
                             forced: mode >= 1, targetRPM: tgt)
        }
    }

    var fanCount: Int { statics.count }
    func range(_ index: Int) -> (min: Double, max: Double)? {
        statics.first { $0.index == index }.map { ($0.min, $0.max) }
    }

    // MARK: - control

    /// Hand the fan back to the SMC's own curve. This is the safe state and
    /// the one everything unwinds to; it must never be allowed to fail
    /// silently, so the result is returned rather than discarded.
    @discardableResult
    func releaseToAuto(_ index: Int) -> Bool {
        SMCFans.write(conn, "F\(index)Md", ui8: 0)
    }

    /// Force a target speed. The caller is responsible for clamping to the
    /// fan's own range; this deliberately does not second-guess it, because
    /// the clamp belongs with the policy that also enforces the failsafe.
    @discardableResult
    func force(_ index: Int, rpm: Double) -> Bool {
        // Order matters. Set the target first, then switch to forced mode --
        // the reverse briefly forces the fan to whatever stale target the SMC
        // still held, which on a machine that was previously at maximum means
        // an audible spike every time a curve nudges the speed.
        guard SMCFans.write(conn, "F\(index)Tg", float: rpm) else { return false }
        return SMCFans.write(conn, "F\(index)Md", ui8: 1)
    }

    // MARK: - raw key access

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private static func put32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        b[off] = UInt8(v & 0xff);         b[off + 1] = UInt8((v >> 8) & 0xff)
        b[off + 2] = UInt8((v >> 16) & 0xff); b[off + 3] = UInt8((v >> 24) & 0xff)
    }

    private static func get32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
    }

    private static func call(_ conn: io_connect_t, _ input: [UInt8]) -> [UInt8]? {
        var inBuf = input
        var outBuf = [UInt8](repeating: 0, count: paramSize)
        var outSize = paramSize
        guard IOConnectCallStructMethod(conn, handleYPCEvent, &inBuf, paramSize,
                                        &outBuf, &outSize) == kIOReturnSuccess,
              outBuf[offResult] == 0 else { return nil }
        return outBuf
    }

    /// Key metadata then payload -- the size and type must come from the SMC
    /// itself, since the same key name carries different widths across Macs.
    private static func read(_ conn: io_connect_t, _ name: String) -> (type: UInt32, bytes: [UInt8])? {
        let key = fourCC(name)

        var info = [UInt8](repeating: 0, count: paramSize)
        put32(&info, offKey, key)
        info[offData8] = cmdKeyInfo
        guard let meta = call(conn, info) else { return nil }
        let size = Int(get32(meta, offDataSize))
        let type = get32(meta, offDataType)
        guard size > 0, size <= paramSize - offBytes else { return nil }

        var req = [UInt8](repeating: 0, count: paramSize)
        put32(&req, offKey, key)
        put32(&req, offDataSize, UInt32(size))
        req[offData8] = cmdReadKey
        guard let out = call(conn, req) else { return nil }
        return (type, Array(out[offBytes..<(offBytes + size)]))
    }

    /// Write a key, using the width and type the SMC itself reports for it.
    /// Writing a guessed width is how you corrupt an adjacent key.
    private static func write(_ conn: io_connect_t, _ name: String, bytes: [UInt8],
                              expectType: String) -> Bool {
        let key = fourCC(name)
        var info = [UInt8](repeating: 0, count: paramSize)
        put32(&info, offKey, key)
        info[offData8] = cmdKeyInfo
        guard let meta = call(conn, info) else { return false }
        let size = Int(get32(meta, offDataSize))
        let type = get32(meta, offDataType)
        let typeName = String(bytes: (0..<4).map { UInt8((type >> (8 * (3 - $0))) & 0xff) },
                              encoding: .ascii) ?? ""
        guard size == bytes.count, typeName == expectType else { return false }

        var req = [UInt8](repeating: 0, count: paramSize)
        put32(&req, offKey, key)
        put32(&req, offDataSize, UInt32(size))
        put32(&req, offDataType, type)
        req[offData8] = cmdWriteKey
        for (i, b) in bytes.enumerated() { req[offBytes + i] = b }
        return call(conn, req) != nil
    }

    private static func write(_ conn: io_connect_t, _ name: String, ui8 v: UInt8) -> Bool {
        write(conn, name, bytes: [v], expectType: "ui8 ")
    }

    private static func write(_ conn: io_connect_t, _ name: String, float v: Double) -> Bool {
        let bits = Float(v).bitPattern
        return write(conn, name, bytes: [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                                         UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)],
                     expectType: "flt ")
    }

    private static func decode(_ v: (type: UInt32, bytes: [UInt8])) -> Double? {
        let b = v.bytes
        let name = String(bytes: (0..<4).map { UInt8((v.type >> (8 * (3 - $0))) & 0xff) },
                          encoding: .ascii) ?? ""
        switch name {
        case "flt ":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil
        case "ui8 ":
            return b.count >= 1 ? Double(b[0]) : nil
        case "ui16":
            return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case "ui32":
            return b.count >= 4 ? Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16
                                         | UInt32(b[2]) << 8 | UInt32(b[3])) : nil
        // Intel-era fixed point: 14-bit integer in the high bits.
        case "fpe2":
            return b.count >= 2 ? Double((UInt16(b[0]) << 8 | UInt16(b[1])) >> 2) : nil
        default:
            return nil
        }
    }
}
