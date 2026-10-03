import AppKit
import CoreGraphics

/// Identifies a monitor across reconnects: EDID vendor, product, serial (same numbers CoreGraphics reports).
public struct DisplayKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var vendor, model, serial: UInt32
    public var description: String { "\(vendor):\(model):\(serial)" }
}

public struct Display {
    public let id: CGDirectDisplayID

    public static func online() -> [Display] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map(Display.init)
    }

    public static func find(_ key: DisplayKey) -> Display? { online().first { $0.key == key } }

    public var key: DisplayKey { DisplayKey(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id)) }
    public var isBuiltin: Bool { CGDisplayIsBuiltin(id) != 0 }
    public var av: AVService? { AVService.find(key) }
    public var mode: CGDisplayMode? { CGDisplayCopyDisplayMode(id) }

    public var modes: [CGDisplayMode] {
        CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] ?? []
    }

    /// 1:1 (non-HiDPI) modes at a resolution, either orientation (rotated displays report swapped sizes), fastest first.
    public func modes(width: Int, height: Int) -> [CGDisplayMode] {
        modes.filter { $0.width == $0.pixelWidth && Set([$0.pixelWidth, $0.pixelHeight]) == Set([width, height]) }
            .sorted { $0.refreshRate > $1.refreshRate }
    }

    /// Refresh rates macOS currently offers at a resolution, rounded to whole Hz.
    public func rates(width: Int, height: Int) -> [Int] {
        Array(Set(modes(width: width, height: height).map { Int($0.refreshRate.rounded()) })).sorted(by: >)
    }

    @discardableResult
    public func set(_ m: CGDisplayMode) -> Bool {
        var c: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&c)
        CGConfigureDisplayWithDisplayMode(c, id, m, nil)
        return CGCompleteDisplayConfiguration(c, .permanently) == .success
    }

    /// True when macOS offers HDR in the current mode.
    public var hdrAvailable: Bool { (MonitorPanel.display(id)?.value(forKey: "hasHDRModes") as? Bool) ?? false }

    public var hdr: Bool {
        get { (MonitorPanel.display(id)?.value(forKey: "preferHDRModes") as? Bool) ?? false }
        nonmutating set { MonitorPanel.display(id)?.setValue(newValue, forKey: "preferHDRModes") }
    }
}

/// Pump AppKit events until `done` holds or `timeout` seconds pass. Display changes from WindowServer only
/// land in this process through the app event loop; a bare run loop gets no callbacks and stale mode lists.
@discardableResult
public func wait(_ timeout: Double, every step: Double = 0.25, until done: () -> Bool = { false }) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if done() { return true }
        if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(step), inMode: .default, dequeue: true) { NSApp.sendEvent(e) }
    }
    return done()
}

/// Display reconfiguration events seen by this process (needs the run loop turning, see `wait`).
public final class DisplayEvents {
    public static let shared = DisplayEvents()
    public var added: Set<CGDirectDisplayID> = []
    public private(set) var last = Date.distantPast
    public var onChange: (() -> Void)?

    private init() {
        CGDisplayRegisterReconfigurationCallback({ id, flags, _ in
            guard !flags.contains(.beginConfigurationFlag) else { return }
            let s = DisplayEvents.shared
            s.last = Date()
            if flags.contains(.addFlag) { s.added.insert(id) }
            s.onChange?()
        }, nil)
    }

    /// Wait until no display event arrived for `quiet` seconds.
    @discardableResult
    public func settle(quiet: Double = 1.5, timeout: Double = 20) -> Bool {
        wait(timeout) { Date().timeIntervalSince(self.last) > quiet }
    }
}

extension Display {
    /// 0, 90, 180 or 270 degrees.
    public var rotation: Int {
        get { Int(CGDisplayRotation(id)) }
        nonmutating set { MonitorPanel.display(id)?.setValue(newValue, forKey: "orientation") }
    }
}

/// Where each display sits and how it is turned, so it can be put back after macOS reshuffles.
public struct Placement: Codable, Hashable, Sendable {
    public var key: DisplayKey
    public var rotation, x, y: Int

    public static func current() -> [Placement] {
        Display.online().map { d in
            let b = CGDisplayBounds(d.id)
            return Placement(key: d.key, rotation: d.rotation, x: Int(b.origin.x), y: Int(b.origin.y))
        }
    }

    /// Rotations first (they change sizes), then all origins in one transaction.
    public static func restore(_ ps: [Placement]) {
        for p in ps { if let d = Display.find(p.key), d.rotation != p.rotation { d.rotation = p.rotation } }
        DisplayEvents.shared.settle(quiet: 1)
        var c: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&c)
        for p in ps { if let d = Display.find(p.key) { CGConfigureDisplayOrigin(c, d.id, Int32(p.x), Int32(p.y)) } }
        CGCompleteDisplayConfiguration(c, .permanently)
        DisplayEvents.shared.settle(quiet: 1)
    }
}
