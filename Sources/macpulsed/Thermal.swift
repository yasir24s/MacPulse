import Darwin
import Foundation
import IOKit

/// Apple Silicon thermal sensors, read through IOHIDEventSystem.
///
/// Classic SMC four-char keys (`TC0P`, `Tp01`) are Intel-era and return
/// nothing on an M-series die -- the sensors moved to IOHID services matching
/// AppleVendor usage page 0xFF00, usage 5. That path is how every third-party
/// Mac temperature tool works here.
///
/// The symbols are real but private, so every one is resolved with `dlsym` at
/// construction. If a future macOS moves or removes them the initialiser
/// returns nil and the daemon simply reports no temperatures -- capability,
/// not version checking, matching how Auscult handles the same problem.
final class Thermal {

    // MARK: private IOKit surface

    private typealias CreateFn   = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias MatchFn    = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias ServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias PropFn     = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias EventFn    = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias ValueFn    = @convention(c) (AnyObject, Int32) -> Double

    private let create: CreateFn
    private let setMatching: MatchFn
    private let copyServices: ServicesFn
    private let copyProperty: PropFn
    private let copyEvent: EventFn
    private let floatValue: ValueFn

    private let client: AnyObject
    private var services: [AnyObject] = []
    private var names: [String] = []

    /// kIOHIDEventTypeTemperature; the field index is the type shifted into
    /// the high half-word, which is what IOHIDEventFieldBase() expands to.
    private static let temperatureType: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            return nil
        }
        func sym<T>(_ name: String, _ as: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let c  = sym("IOHIDEventSystemClientCreate", CreateFn.self),
              let m  = sym("IOHIDEventSystemClientSetMatching", MatchFn.self),
              let sv = sym("IOHIDEventSystemClientCopyServices", ServicesFn.self),
              let pr = sym("IOHIDServiceClientCopyProperty", PropFn.self),
              let ev = sym("IOHIDServiceClientCopyEvent", EventFn.self),
              let fv = sym("IOHIDEventGetFloatValue", ValueFn.self)
        else { return nil }
        create = c; setMatching = m; copyServices = sv
        copyProperty = pr; copyEvent = ev; floatValue = fv

        guard let raw = create(kCFAllocatorDefault) else { return nil }
        client = raw.takeRetainedValue()

        // AppleVendor page, TemperatureSensor usage.
        let match: [String: Any] = ["PrimaryUsagePage": 0xFF00, "PrimaryUsage": 5]
        _ = setMatching(client, match as CFDictionary)

        guard let list = copyServices(client)?.takeRetainedValue() as? [AnyObject],
              !list.isEmpty else { return nil }
        services = list
        names = list.map { svc in
            (copyProperty(svc, "Product" as CFString)?.takeRetainedValue() as? String) ?? "unnamed"
        }
    }

    private func read(_ index: Int) -> Double? {
        guard index < services.count,
              let e = copyEvent(services[index], Self.temperatureType, 0, 0) else { return nil }
        let v = floatValue(e.takeRetainedValue(), Self.temperatureField)
        // Unpopulated sensors report small negatives (this M2 shows tdev4/tdev5
        // at -1.7 °C). Anything at or below freezing is not a real reading on a
        // running machine.
        return v.isFinite && v > 1 && v < 150 ? v : nil
    }

    /// Every sensor that answered this tick, with its hardware name.
    func all() -> [(name: String, celsius: Double)] {
        (0..<services.count).compactMap { i in read(i).map { (names[i], $0) } }
    }

    /// Hottest sensor whose name matches any fragment. Apple exposes several
    /// dies per block (pACC/eACC clusters, multiple GPU sensors); the maximum
    /// is the number a thermal readout should show.
    private func hottest(_ fragments: [String], _ sensors: [(name: String, celsius: Double)]) -> Double? {
        sensors.filter { s in fragments.contains { s.name.localizedCaseInsensitiveContains($0) } }
               .map(\.celsius).max()
    }

    struct Reading {
        /// Hottest SoC die sensor -- the headline number, and what other Mac
        /// temperature tools display.
        var die: Double?
        /// Secondary PMU die group; runs cooler than the main one.
        var pmu2: Double?
        var nand: Double?
        var battery: Double?
        var sensorCount: Int
        /// Every valid sensor, hottest first. No interpretation applied.
        var sensors: [(name: String, celsius: Double)]
    }

    /// Last reading per sensor index, for the partial sweep.
    private var cache: [Double?] = []

    /// The sensors whose value is shown or rolled up every second: every
    /// PMU tdie (the die readout and the three hottest are always these), the
    /// SSD, and one battery cell. 10 of 38 on Mac14,7. PMU2, tdev, tcal and
    /// the other five cells only feed the sensor count and the long list.
    private lazy var headline: [Int] = {
        var idx: [Int] = []
        var haveBattery = false
        for (i, n) in names.enumerated() {
            if n.contains("PMU tdie") || n.contains("NAND") { idx.append(i) }
            else if !haveBattery && n.localizedCaseInsensitiveContains("gas gauge") {
                idx.append(i); haveBattery = true
            }
        }
        return idx
    }()

    /// Reading all 38 sensors cost 2.4 ms per tick at 1 Hz. A partial sweep
    /// refreshes only `headline`, reusing each other sensor's last value
    /// (never older than one full-sweep interval), which keeps every figure
    /// the panel foregrounds fresh while cutting most of the IOHID traffic.
    func reading(full: Bool) -> Reading {
        if full || cache.count != services.count {
            cache = (0..<services.count).map(read)
        } else {
            for i in headline { cache[i] = read(i) }
        }
        return rollup(zip(names, cache).compactMap { n, v in v.map { (n, $0) } })
    }

    func reading() -> Reading { reading(full: true) }

    private func rollup(_ s: [(name: String, celsius: Double)]) -> Reading {
        // "tcal" is a calibration reference, not a measured temperature --
        // excluded from anything presented as a machine temperature.
        let measured = s.filter { !$0.name.localizedCaseInsensitiveContains("tcal") }
        // This Mac names nothing CPU/GPU/SOC/ANE. Report what the hardware
        // actually exposes rather than mapping sensors onto labels it never
        // claimed -- a guessed "GPU temp" would be fabrication.
        return Reading(
            die:     hottest(["PMU tdie"], measured),
            pmu2:    hottest(["PMU2 tdie"], measured),
            nand:    hottest(["NAND"], measured),
            battery: hottest(["gas gauge", "battery"], measured),
            sensorCount: measured.count,
            sensors: measured.sorted { $0.celsius > $1.celsius }
        )
    }

    var sensorNames: [String] { names }
}
