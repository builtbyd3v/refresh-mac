import CoreGraphics
import Foundation

public struct ScanReport: Sendable {
    public var width, height: Int
    public var factoryMax: Int   // fastest rate macOS offered with the monitor's own EDID
    public var edidMax: Int      // fastest rate the monitor advertises (the scan never goes above it)
    public var ceiling: Int      // fastest rate macOS accepts with the current set of monitors
    public var hdrCeiling: Int?  // fastest rate that still offers HDR
    public var edid: EDID        // EDID to inject: factory plus the rates above
}

public enum ScanError: Error, CustomStringConvertible {
    case notFound, noEDID, noTemplate, timeout(String)
    public var description: String {
        switch self {
        case .notFound: "display not found or has no AV service (built-in, AirPlay, DisplayLink?)"
        case .noEDID: "could not read the monitor's EDID"
        case .noTemplate: "no timing at native resolution to base new rates on"
        case .timeout(let s): "timed out waiting for the display: \(s)"
        }
    }
}

/// Finds the fastest refresh macOS will drive with the current monitors, by injecting candidate timings and
/// reading back which ones macOS offers. Dual-pipe modes vanish when every display engine is busy, so the
/// offered list is the test. HDR is then found by setting modes, since it is only reported for the current mode.
public struct Scanner {
    public let key: DisplayKey
    public var log: (String) -> Void = { print($0) }

    public init(key: DisplayKey, log: @escaping (String) -> Void = { print($0) }) {
        self.key = key
        self.log = log
    }

    public func run(hdr checkHDR: Bool = true) throws -> ScanReport {
        guard let start = Display.find(key), start.av != nil else { throw ScanError.notFound }
        let placements = Placement.current() // a new EDID makes macOS reset rotation, scaling and layout
        do {
            return try scan(start, placements, checkHDR)
        } catch {
            log("scan failed, clearing the override")
            try? apply(nil)
            Placement.restore(placements)
            throw error
        }
    }

    private func scan(_ start: Display, _ placements: [Placement], _ checkHDR: Bool) throws -> ScanReport {
        let startHz = start.mode.map { Int($0.refreshRate.rounded()) }, startHDR = start.hdr

        log("clearing any EDID override")
        try apply(nil)
        guard let factory = AVService.find(key)?.edid, let (w, h) = factory.native else { throw ScanError.noEDID }
        let native = factory.timings.filter { $0.hActive == w && $0.vActive == h }
        let edidMax = native.map(\.hz).max()!
        let factoryMax = try display().rates(width: w, height: h).first ?? 0
        guard let template = native.filter({ $0.hz <= factoryMax }).max(by: { $0.hz < $1.hz }) else { throw ScanError.noTemplate }
        log("\(w)x\(h): offered up to \(factoryMax)Hz, monitor advertises \(edidMax)Hz, new timings copy the \(template.hz)Hz one")

        var ceiling = factoryMax
        if factoryMax < edidMax {
            ceiling = try search(from: factoryMax, below: edidMax) { cs in
                try apply(factory.appending(cs.map { template.at(hz: $0) }))
                let offered = Set(try display().rates(width: w, height: h))
                log("  tried \(cs.map(String.init).joined(separator: " ")): offered \(cs.filter(offered.contains).map(String.init).joined(separator: " "))")
                return cs.filter(offered.contains).max()
            }
        } else {
            log("already offered at the monitor's max; nothing to unlock with this set of monitors")
        }
        log("ceiling: \(ceiling)Hz")

        var hdrCeiling: Int?
        if checkHDR && ceiling > factoryMax {
            if try hdrAt(factoryMax, w, h) {
                hdrCeiling = factoryMax
                // Probe the ceiling first: if it keeps HDR the search is over.
                try apply(factory.appending([template.at(hz: ceiling)]))
                if try hdrAt(ceiling, w, h) { hdrCeiling = ceiling } else {
                    hdrCeiling = try search(from: factoryMax, below: ceiling) { cs in
                        try apply(factory.appending(cs.map { template.at(hz: $0) }))
                        var lo = 0, hi = cs.count - 1, best: Int?
                        while lo <= hi { // binary search, each probe is a mode switch
                            let m = (lo + hi) / 2
                            if try hdrAt(cs[m], w, h) { best = cs[m]; lo = m + 1 } else { hi = m - 1 }
                        }
                        log("  HDR up to \(best.map { "\($0)Hz" } ?? "none") among \(cs.map(String.init).joined(separator: " "))")
                        return best
                    }
                }
            } else {
                log("no HDR at \(factoryMax)Hz, skipping HDR search")
            }
            log("HDR ceiling: \(hdrCeiling.map { "\($0)Hz" } ?? "none")")
        }

        // Final set: the two ceilings plus common rates in between, fastest first.
        var rates = [ceiling] + [hdrCeiling].compactMap { $0 }
        for r in [300, 240, 280, 200, 165] where rates.count < 5 && r > factoryMax && r < ceiling && !rates.contains(r) { rates.append(r) }
        rates = Array(Set(rates)).sorted(by: >)
        let edid = ceiling > factoryMax ? factory.appending(rates.map { template.at(hz: $0) }) : factory
        try apply(edid == factory ? nil : edid)

        // Leave the monitor as found if that rate still exists, else at the fastest rate that keeps the HDR setting.
        let d = try display(), offered = d.modes(width: w, height: h)
        let wantHz = startHz.flatMap { hz in offered.contains { Int($0.refreshRate.rounded()) == hz } ? hz : nil }
            ?? (startHDR ? hdrCeiling ?? factoryMax : ceiling)
        if let m = offered.first(where: { Int($0.refreshRate.rounded()) == wantHz }) { d.set(m) }
        DisplayEvents.shared.settle(quiet: 1)
        if startHDR { wait(3) { d.hdrAvailable }; d.hdr = true }
        Placement.restore(placements)
        return ScanReport(width: w, height: h, factoryMax: factoryMax, edidMax: edidMax, ceiling: ceiling, hdrCeiling: hdrCeiling, edid: edid)
    }

    /// Highest passing rate in (lo, hi), with `lo` known good and `hi` known bad. Each round tests up to
    /// 5 evenly spaced candidates (a DisplayID block holds 5 timings) and returns the best that passed.
    func search(from lo: Int, below hi: Int, round: ([Int]) throws -> Int?) rethrows -> Int {
        var lo = lo, hi = hi
        while hi - lo > 1 {
            let n = min(5, hi - lo - 1)
            let cs = Array(Set((1...n).map { lo + (hi - lo) * $0 / (n + 1) })).sorted()
            if let best = try round(cs) { lo = best }
            hi = cs.first { $0 > lo } ?? hi // assumes monotonic: everything above the best failed
        }
        return lo
    }

    func display() throws -> Display {
        guard let d = Display.find(key) else { throw ScanError.timeout("monitor did not come back") }
        return d
    }

    /// Inject (or clear) the EDID, then wait for the monitor to drop, come back, and macOS to finish reconfiguring.
    public func apply(_ e: EDID?) throws {
        guard let av = AVService.find(key) else { throw ScanError.notFound }
        let ev = DisplayEvents.shared, before = av.edid
        ev.added = []
        let r = av.setEDID(e)
        if r != kIOReturnSuccess { log("  set EDID returned 0x\(String(r, radix: 16))") }
        if before != (e ?? AVService.find(key)?.edid) {
            // Mode lists read before the reconnect are stale, so wait for the add event itself.
            if !wait(15, until: { ev.added.contains { Display(id: $0).key == key } }) { log("  no reconnect seen") }
        }
        guard ev.settle(), Display.find(key) != nil else { throw ScanError.timeout("monitor did not settle") }
    }

    /// Switch to the rate and report whether macOS offers HDR in it.
    func hdrAt(_ hz: Int, _ w: Int, _ h: Int) throws -> Bool {
        let d = try display()
        guard let m = d.modes(width: w, height: h).first(where: { Int($0.refreshRate.rounded()) == hz }) else {
            log("  \(hz)Hz not offered; have \(d.rates(width: w, height: h)), now \(d.mode.map { "\($0.width)x\($0.height)@\($0.refreshRate)" } ?? "?")")
            return false
        }
        d.set(m)
        DisplayEvents.shared.settle(quiet: 1)
        let ok = wait(3) { d.hdrAvailable }
        log("  \(hz)Hz: HDR \(ok ? "yes" : "no")")
        return ok
    }
}
