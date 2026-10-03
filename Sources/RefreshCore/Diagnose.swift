import CoreGraphics
import Foundation
import IOKit

/// What the hardware can do right now and what software cannot fix. Read-only; safe to run any time.
public struct Diagnosis {
    public struct Port { public let name: String; public let provisioned, active: [String] }
    public struct External { public let name: String; public let id: CGDirectDisplayID; public let offeredMax, advertisedMax: Int; public let scanned: Bool }

    public let chip: String
    public let engines: Int
    public let externals: [External]
    public let ports: [Port]
    public let displayLink: Bool
    public let mirrored: Bool

    public static func run() -> Diagnosis {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)

        let externals = Display.online().filter { !$0.isBuiltin }.map { d -> External in
            let e = d.av?.edid
            guard let e, let (w, h) = e.native else { return External(name: e?.name ?? "?", id: d.id, offeredMax: 0, advertisedMax: 0, scanned: false) }
            return External(name: e.name ?? "?", id: d.id, offeredMax: d.rates(width: w, height: h).first ?? 0,
                            advertisedMax: e.timings.filter { $0.hActive == w && $0.vActive == h }.map(\.hz).max() ?? 0, scanned: e.hasAppendedBlock)
        }

        return Diagnosis(
            chip: String(cString: buf),
            // One external display engine per dispextN node (built-in panel uses disp0).
            engines: (0..<8).filter { service(IOServiceNameMatching("dispext\($0)")) }.count,
            externals: externals,
            ports: registry("AppleHPMInterfaceType10") { s in
                Port(name: property(s, "Description") ?? "?", provisioned: strings(s, "TransportsProvisioned"), active: strings(s, "TransportsActive"))
            },
            displayLink: service(["IOProviderClass": "IOUSBHostDevice", "idVendor": 0x17e9] as NSDictionary as CFDictionary),
            mirrored: Display.online().contains { CGDisplayMirrorsDisplay($0.id) != kCGNullDirectDisplay }
        )
    }

    /// Human-readable summary: hardware first, then findings.
    public var report: String {
        var out = ["\(chip): \(engines) external display engine\(engines == 1 ? "" : "s"), \(externals.count) external display\(externals.count == 1 ? "" : "s") on"]
        for e in externals { out.append("  \(e.id)  \(e.name)  offered max \(e.offeredMax)Hz  advertised \(e.advertisedMax)Hz\(e.scanned ? "  (scanned rates injected)" : "")") }
        for p in ports { out.append("  \(p.name)  active: \(p.active.isEmpty ? "none" : p.active.joined(separator: ","))  set up: \(p.provisioned.joined(separator: ","))") }
        out.append("  DisplayLink: \(displayLink ? "yes" : "no")  mirroring: \(mirrored ? "yes" : "no")")
        out.append(findings.isEmpty ? "\nNo problems found." : "\n" + findings.map { "- " + $0 }.joined(separator: "\n"))
        return out.joined(separator: "\n")
    }

    /// Plain-language problems, each with what to do. Empty means nothing to report.
    public var findings: [String] {
        var out: [String] = []
        for p in ports where p.provisioned.contains("DisplayPort") && !p.active.contains("DisplayPort") {
            out.append("\(p.name): the USB-C display is set up but dark (wrong plug order). Unplug the HDMI cable and plug it back in.")
        }
        if externals.count > 1 {
            for e in externals where !e.scanned && e.advertisedMax > e.offeredMax && e.offeredMax > 0 {
                out.append("\(e.name): monitor advertises \(e.advertisedMax)Hz, macOS offers \(e.offeredMax)Hz. The fastest mode needs two display engines. Run `refresh scan \(e.id)` to find the fastest rate that fits one.")
            }
        }
        if mirrored { out.append("A display is mirrored. MST \"dual HDMI\" hubs and HDMI splitters can only mirror on macOS; use one cable per monitor.") }
        if displayLink { out.append("DisplayLink adapter found. It bypasses the engine limit but uses CPU and cannot do high refresh rates or HDR.") }
        return out
    }
}

private func service(_ match: CFDictionary) -> Bool {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, match)
    defer { IOObjectRelease(s) }
    return s != 0
}

private func registry<T>(_ cls: String, _ f: (io_service_t) -> T) -> [T] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var out: [T] = []
    while case let s = IOIteratorNext(it), s != 0 { out.append(f(s)); IOObjectRelease(s) }
    return out
}

private func property<T>(_ s: io_service_t, _ key: String) -> T? {
    IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? T
}

private func strings(_ s: io_service_t, _ key: String) -> [String] { property(s, key) ?? [] }
