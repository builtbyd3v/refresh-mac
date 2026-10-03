import CoreGraphics
import Foundation

/// How one monitor should look whenever it connects as part of a profile.
public struct MonitorSettings: Codable, Sendable {
    public var key: DisplayKey
    public var edid: EDID?  // EDID to keep injected; nil leaves the monitor's own
    public var width, height, pixelWidth, pixelHeight, hz: Int
    public var hdr: Bool

    /// Same size and rate, in either orientation (rotated displays report swapped sizes).
    public func matches(_ m: CGDisplayMode) -> Bool {
        Int(m.refreshRate.rounded()) == hz
            && [(m.width, m.height), (m.height, m.width)].contains { $0 == (width, height) }
            && [(m.pixelWidth, m.pixelHeight), (m.pixelHeight, m.pixelWidth)].contains { $0 == (pixelWidth, pixelHeight) }
    }
}

/// Settings for one exact set of connected displays, built-in included.
public struct Profile: Codable, Sendable {
    public var monitors: [MonitorSettings]
    public var placements: [Placement]
    public var keys: Set<DisplayKey> { Set(placements.map(\.key)) }

    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Refresh/profiles.json")

    /// Snapshot of the current setup.
    public static func current() -> Profile {
        let monitors = Display.online().filter { !$0.isBuiltin }.compactMap { d -> MonitorSettings? in
            guard let m = d.mode else { return nil }
            // note: stores the current EDID even when it is the monitor's own; injecting an identical EDID never happens since the keeper compares first
            return MonitorSettings(key: d.key, edid: d.av?.edid, width: m.width, height: m.height, pixelWidth: m.pixelWidth,
                                   pixelHeight: m.pixelHeight, hz: Int(m.refreshRate.rounded()), hdr: d.hdrAvailable && d.hdr)
        }
        return Profile(monitors: monitors, placements: Placement.current())
    }

    /// Put this setup back now, blocking for a few seconds (undo after a scan). The keeper does the same in the background.
    public func restore() throws {
        for m in monitors {
            if let want = m.edid, AVService.find(m.key)?.edid != want {
                let s = Scanner(key: m.key)
                try s.apply(want.hasAppendedBlock ? want : nil)
                if AVService.find(m.key)?.edid != want { try s.apply(want) } // an older override that is not ours
            }
            guard let d = Display.find(m.key) else { continue }
            if d.mode.map(m.matches) != true, let mode = d.modes.first(where: m.matches) {
                d.set(mode)
                DisplayEvents.shared.settle(quiet: 1)
            }
            if m.hdr { wait(3) { d.hdrAvailable } }
            if d.hdr != m.hdr { d.hdr = m.hdr }
        }
        Placement.restore(placements)
    }

    /// Saved profiles. Throws on a corrupt file so a later save cannot silently wipe it.
    public static func load() throws -> [Profile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([Profile].self, from: Data(contentsOf: url))
    }

    /// Store, replacing any profile for the same set of displays.
    public func save() throws {
        let all = try Self.load().filter { $0.keys != keys } + [self]
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(all).write(to: Self.url, options: .atomic)
    }
}

extension EDID: Codable {
    public init(from decoder: Decoder) throws {
        guard let e = EDID(try decoder.singleValueContainer().decode(Data.self)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not an EDID"))
        }
        self = e
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(data)
    }
}
