import Foundation

/// One video timing. Pixel clock in 10 kHz units, everything else in pixels or lines.
public struct Timing: Equatable, Sendable {
    public var pixelClock: Int
    public var hActive, hBlank, hFront, hSync: Int
    public var vActive, vBlank, vFront, vSync: Int
    public var hPositive = true, vPositive = true
    public var aspect: UInt8 = 8 // DisplayID Type I aspect code, 8 = undefined

    public var refresh: Double { Double(pixelClock) * 10_000 / Double((hActive + hBlank) * (vActive + vBlank)) }
    public var hz: Int { Int(refresh.rounded()) }

    /// Same blanking and sync, pixel clock scaled to hit `hz`.
    public func at(hz: Int) -> Timing {
        var t = self
        t.pixelClock = Int((Double((hActive + hBlank) * (vActive + vBlank) * hz) / 10_000).rounded())
        return t
    }

    /// 18-byte EDID detailed timing descriptor. Nil for descriptors that are not timings, and for interlaced ones.
    init?(dtd b: ArraySlice<UInt8>) {
        let b = Array(b)
        pixelClock = Int(b[0]) | Int(b[1]) << 8
        guard pixelClock > 0, b[17] & 0x80 == 0 else { return nil }
        hActive = Int(b[2]) | Int(b[4] >> 4) << 8
        hBlank = Int(b[3]) | Int(b[4] & 0xf) << 8
        vActive = Int(b[5]) | Int(b[7] >> 4) << 8
        vBlank = Int(b[6]) | Int(b[7] & 0xf) << 8
        hFront = Int(b[8]) | Int(b[11] >> 6 & 3) << 8
        hSync = Int(b[9]) | Int(b[11] >> 4 & 3) << 8
        vFront = Int(b[10] >> 4) | Int(b[11] >> 2 & 3) << 4
        vSync = Int(b[10] & 0xf) | Int(b[11] & 3) << 4
        if b[17] & 0x18 == 0x18 { vPositive = b[17] & 4 != 0; hPositive = b[17] & 2 != 0 }
        let ratios: [(Int, Int)] = [(1, 1), (5, 4), (4, 3), (15, 9), (16, 9), (16, 10), (64, 27), (256, 135)]
        if let i = ratios.firstIndex(where: { abs(Double(hActive) / Double(vActive) - Double($0.0) / Double($0.1)) < 0.01 }) { aspect = UInt8(i) }
    }

    /// 20-byte DisplayID 1.x Type I detailed timing. Nil for interlaced ones.
    init?(typeI b: ArraySlice<UInt8>) {
        let b = Array(b)
        guard b[3] & 0x10 == 0 else { return nil }
        func w(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        pixelClock = (Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16) + 1
        aspect = b[3] & 0xf
        hActive = w(4) + 1; hBlank = w(6) + 1; hFront = (w(8) & 0x7fff) + 1; hPositive = w(8) & 0x8000 != 0; hSync = w(10) + 1
        vActive = w(12) + 1; vBlank = w(14) + 1; vFront = (w(16) & 0x7fff) + 1; vPositive = w(16) & 0x8000 != 0; vSync = w(18) + 1
    }

    var typeI: [UInt8] {
        let pc = pixelClock - 1
        var o: [UInt8] = [UInt8(pc & 0xff), UInt8(pc >> 8 & 0xff), UInt8(pc >> 16 & 0xff), aspect]
        for v in [hActive - 1, hBlank - 1, hFront - 1 | (hPositive ? 0x8000 : 0), hSync - 1,
                  vActive - 1, vBlank - 1, vFront - 1 | (vPositive ? 0x8000 : 0), vSync - 1] {
            o += [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)]
        }
        return o
    }
}

public struct EDID: Equatable, Sendable {
    public private(set) var bytes: [UInt8]

    public init?(_ d: Data) {
        guard d.count >= 128, d.count % 128 == 0, d.starts(with: [0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0]) else { return nil }
        bytes = Array(d)
    }

    public var data: Data { Data(bytes) }
    public var key: DisplayKey {
        DisplayKey(vendor: UInt32(bytes[8]) << 8 | UInt32(bytes[9]),
                   model: UInt32(bytes[10]) | UInt32(bytes[11]) << 8,
                   serial: bytes[12...15].reversed().reduce(0) { $0 << 8 | UInt32($1) })
    }

    public var name: String? {
        for o in stride(from: 54, to: 126, by: 18) where bytes[o] == 0 && bytes[o + 1] == 0 && bytes[o + 3] == 0xfc {
            return String(decoding: bytes[(o + 5)..<(o + 18)], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private var extensions: [Int] { Array(stride(from: 128, to: bytes.count, by: 128)) }

    /// All detailed timings: base block, CTA-861 blocks, DisplayID Type I blocks.
    public var timings: [Timing] {
        var out = stride(from: 54, to: 126, by: 18).compactMap { Timing(dtd: bytes[$0..<($0 + 18)]) }
        for e in extensions {
            if bytes[e] == 0x02, bytes[e + 2] >= 4 {
                out += stride(from: e + Int(bytes[e + 2]), through: e + 127 - 18, by: 18).compactMap { Timing(dtd: bytes[$0..<($0 + 18)]) }
            } else if bytes[e] == 0x70 {
                let end = e + 5 + min(Int(bytes[e + 2]), 121)
                var i = e + 5
                while i + 3 <= end, bytes[i] != 0 {
                    let len = Int(bytes[i + 2])
                    if bytes[i] == 0x03 {
                        out += stride(from: i + 3, through: min(i + 3 + len, end) - 20, by: 20).compactMap { Timing(typeI: bytes[$0..<($0 + 20)]) }
                    }
                    i += 3 + len
                }
            }
        }
        return out
    }

    /// Largest active area among the timings: the panel's native resolution.
    public var native: (width: Int, height: Int)? {
        timings.max { $0.hActive * $0.vActive < $1.hActive * $1.vActive }.map { ($0.hActive, $0.vActive) }
    }

    /// Copy with one extra DisplayID extension block holding up to 5 Type I timings. Original timings stay untouched.
    public func appending(_ ts: [Timing]) -> EDID {
        precondition((1...5).contains(ts.count), "a DisplayID block fits 1 to 5 Type I timings")
        var b = bytes
        // Extension count lives in the CTA HF-EEODB block when present (HDMI 2.1 EDIDs over 256 bytes), else base byte 126.
        if let e = eeodbCount { b[e] += 1; fix(&b, block: e / 128 * 128) } else { b[126] += 1; fix(&b, block: 0) }
        var x = [UInt8](repeating: 0, count: 128)
        x[0...7] = [0x70, 0x12, 121, 0, 0, 0x03, 0x01, UInt8(20 * ts.count)]
        for (k, t) in ts.enumerated() { x.replaceSubrange((8 + 20 * k)..<(28 + 20 * k), with: t.typeI) }
        x[126] = Self.checksum(x[1..<126])
        x[127] = Self.checksum(x[0..<127])
        b += x
        return EDID(Data(b))!
    }

    /// True when the last block is one `appending` wrote, i.e. a scan result is injected.
    // note: header match only; a monitor whose own last block is a bare one-section Type I DisplayID extension would read as scanned
    public var hasAppendedBlock: Bool {
        bytes.count > 128 && Array(bytes[(bytes.count - 128)..<(bytes.count - 121)]) == [0x70, 0x12, 121, 0, 0, 0x03, 0x01]
    }

    /// Offset of the HF-EEODB block-count byte in the first CTA extension, if any.
    private var eeodbCount: Int? {
        guard bytes.count > 128, bytes[128] == 0x02 else { return nil }
        var i = 132
        while i < 128 + Int(bytes[130]) {
            let tag = bytes[i] >> 5, len = Int(bytes[i] & 0x1f)
            if tag == 7, len >= 2, bytes[i + 1] == 0x78 { return i + 2 }
            i += 1 + len
        }
        return nil
    }

    private func fix(_ b: inout [UInt8], block o: Int) { b[o + 127] = Self.checksum(b[o..<(o + 127)]) }
    static func checksum(_ s: ArraySlice<UInt8>) -> UInt8 { UInt8((256 - s.reduce(0) { ($0 + Int($1)) % 256 }) % 256) }
}
