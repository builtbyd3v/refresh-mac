import Foundation
import Testing
@testable import RefreshCore

let xg27 = EDID(try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../reference/xg27acdng.edid.bin")))!

@Test func parsesXG27() {
    #expect(xg27.key == DisplayKey(vendor: 1715, model: 10228, serial: 0x0101_0101))
    #expect(xg27.name == "XG27ACDNG")
    #expect(xg27.native! == (2560, 1440))
    let rates = xg27.timings.filter { $0.hActive == 2560 }.map(\.hz)
    #expect(Set(rates) == [60, 120, 144, 180, 360])
}

@Test func appendsDisplayIDBlock() {
    let t180 = xg27.timings.first { $0.hActive == 2560 && $0.hz == 180 }!
    let e = xg27.appending([345, 325].map { t180.at(hz: $0) })
    #expect(e.bytes.count == 512)
    for b in stride(from: 0, to: 512, by: 128) { #expect(e.bytes[b..<(b + 128)].reduce(0) { $0 + Int($1) } % 256 == 0) }
    #expect(e.bytes[0x84...0x86] == [0xe2, 0x78, 3]) // HF-EEODB count bumped
    #expect(e.bytes[384 + 1..<384 + 127].reduce(0) { $0 + Int($1) } % 256 == 0) // DisplayID section checksum
    #expect(Array(e.bytes.prefix(128)) == Array(xg27.bytes.prefix(128)))
    let added = e.timings.suffix(2)
    #expect(added.map(\.hz) == [345, 325])
    #expect(added.first!.pixelClock == 147_329) // 2720 x 1570 x 345 Hz = 1473.29 MHz, the proven timing
    #expect(added.allSatisfy { $0.hBlank == 160 && $0.vBlank == 130 && $0.hFront == 48 && $0.vSync == 5 })
}

@Test func searchConverges() {
    let s = Scanner(key: xg27.key)
    #expect(s.search(from: 180, below: 360) { cs in cs.filter { $0 <= 345 }.max() } == 345)
    #expect(s.search(from: 180, below: 345) { cs in cs.filter { $0 <= 325 }.max() } == 325)
    #expect(s.search(from: 180, below: 360) { _ in nil } == 180)
}
