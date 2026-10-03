import CoreGraphics
import Foundation
import IOKit

// Private IOAVService API (IOKit, resolved at runtime) for reading and overriding a monitor's EDID.
private enum AVAPI {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<AnyObject>?
    typealias Copy = @convention(c) (AnyObject, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
    typealias Set = @convention(c) (AnyObject, UInt32, CFData?) -> IOReturn

    static let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
    static func sym<T>(_ name: String) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
    static let create: Create? = sym("IOAVServiceCreateWithService")
    static let copyEDID: Copy? = sym("IOAVServiceCopyEDID")
    static let setVirtualEDID: Set? = sym("IOAVServiceSetVirtualEDIDMode")
}

public struct AVService {
    let ref: AnyObject

    public static var available: Bool { AVAPI.create != nil && AVAPI.copyEDID != nil && AVAPI.setVirtualEDID != nil }

    /// Every external display output (DCPAVServiceProxy) that currently reports an EDID.
    public static func all() -> [AVService] {
        guard let create = AVAPI.create else { return [] }
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [AVService] = []
        while case let s = IOIteratorNext(it), s != 0 {
            if let ref = create(kCFAllocatorDefault, s)?.takeRetainedValue() { out.append(AVService(ref: ref)) }
            IOObjectRelease(s)
        }
        return out
    }

    public static func find(_ key: DisplayKey) -> AVService? { all().first { $0.edid?.key == key } }

    /// Current EDID: the virtual one while an override is active, else the monitor's own.
    public var edid: EDID? {
        var cf: Unmanaged<CFData>?
        guard let copy = AVAPI.copyEDID, copy(ref, &cf) == kIOReturnSuccess, let d = cf?.takeRetainedValue() else { return nil }
        return EDID(d as Data)
    }

    /// Override the EDID; nil restores the monitor's own. macOS drops the override on replug and sleep.
    @discardableResult
    public func setEDID(_ e: EDID?) -> IOReturn {
        guard let set = AVAPI.setVirtualEDID else { return kIOReturnUnsupported }
        return e.map { set(ref, 1, $0.data as CFData) } ?? set(ref, 0, nil)
    }
}

// Private MonitorPanel.framework (what System Settings uses) for HDR and rotation.
enum MonitorPanel {
    static let loaded = dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_NOW) != nil

    static func display(_ id: CGDirectDisplayID) -> NSObject? {
        guard loaded, let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        let displays = cls.init().value(forKey: "displays") as? [NSObject] ?? []
        return displays.first { ($0.value(forKey: "displayID") as? NSNumber)?.uint32Value == id }
    }
}
