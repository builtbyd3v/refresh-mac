import AppKit
import RefreshCore

// Display-change events from WindowServer only reach a process with an app connection; no Dock icon.
NSApplication.shared.setActivationPolicy(.prohibited)
NSApp.finishLaunching()

let usage = """
usage: refresh list                 displays, current mode, offered and advertised max
       refresh edid <id> [file]     print the current EDID's timings (and save it)
       refresh scan <id> [--no-hdr] find the fastest rate (and HDR rate) this setup accepts
       refresh reset [<id>]         drop EDID overrides, back to the monitor's own
       refresh save                 remember the current setup for this set of displays
       refresh keep                 stay running, put saved setups back after replug and sleep
       refresh diagnose             chip, display engines, ports, and problems software cannot fix
"""

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }

func display(_ arg: String?) -> Display {
    guard let arg, let id = UInt32(arg), let d = Display.online().first(where: { $0.id == id }) else { fail("unknown display id; see `refresh list`") }
    return d
}

func hz(_ m: CGDisplayMode?) -> String { m.map { "\($0.pixelWidth)x\($0.pixelHeight)@\(Int($0.refreshRate.rounded()))" } ?? "?" }

guard AVService.available else { fail("private IOAVService API missing on this macOS") }
let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "list":
    for d in Display.online() {
        let e = d.av?.edid
        let b = CGDisplayBounds(d.id)
        var line = "\(d.id)  \(d.isBuiltin ? "built-in" : e?.name ?? "?")  [\(d.key)]  now \(hz(d.mode))  at \(Int(b.minX)),\(Int(b.minY)) rot \(d.rotation)"
        if let e, let (w, h) = e.native {
            line += "  offered max \(d.rates(width: w, height: h).first ?? 0)Hz  advertised \(e.timings.filter { $0.hActive == w && $0.vActive == h }.map(\.hz).max() ?? 0)Hz"
            line += "  HDR \(d.hdrAvailable ? (d.hdr ? "on" : "off") : "n/a")"
        }
        print(line)
    }

case "edid":
    guard let e = display(args.dropFirst().first).av?.edid else { fail("no EDID for that display") }
    print("\(e.name ?? "?")  [\(e.key)]  \(e.bytes.count) bytes")
    for t in e.timings {
        print(String(format: "  %dx%d @ %7.3fHz  pclk %7.2f MHz  htot %d  vtot %d", t.hActive, t.vActive, t.refresh, Double(t.pixelClock) / 100, t.hActive + t.hBlank, t.vActive + t.vBlank))
    }
    if args.count > 2 { try e.data.write(to: URL(fileURLWithPath: args[2])) }

case "scan":
    let d = display(args.dropFirst().first)
    do {
        let r = try Scanner(key: d.key).run(hdr: !args.contains("--no-hdr"))
        print("\n\(r.width)x\(r.height): max \(r.ceiling)Hz, HDR max \(r.hdrCeiling.map { "\($0)Hz" } ?? "n/a") (was \(r.factoryMax)Hz, monitor advertises \(r.edidMax)Hz)")
        print("override stays until replug or sleep; `refresh reset \(d.id)` to undo")
    } catch { fail("scan failed: \(error)") }

case "reset":
    let targets = args.count > 1 ? [display(args[1])] : Display.online().filter { !$0.isBuiltin }
    for d in targets { print("\(d.id): 0x\(String(d.av?.setEDID(nil) ?? 0, radix: 16))") }

case "save":
    let p = Profile.current()
    do { try p.save() } catch { fail("save failed: \(error)") }
    for m in p.monitors { print("\(m.key)  \(m.pixelWidth)x\(m.pixelHeight)@\(m.hz)  HDR \(m.hdr ? "on" : "off")  EDID \(m.edid?.bytes.count ?? 0) bytes") }
    print("saved for \(p.keys.count) displays in \(Profile.url.path)")

case "keep":
    setvbuf(stdout, nil, _IOLBF, 0) // line-buffered so a LaunchAgent log file stays current
    let profiles: [Profile]
    do { profiles = try Profile.load() } catch { fail("cannot read \(Profile.url.path): \(error)") }
    if profiles.isEmpty { fail("no saved setup; run `refresh save` first") }
    let keeper = Keeper(profiles: profiles) { print("\(Date().formatted(date: .omitted, time: .standard)) \($0)") }
    keeper.start()
    NSApp.run()

case "diagnose":
    print(Diagnosis.run().report)

default:
    print(usage)
}
