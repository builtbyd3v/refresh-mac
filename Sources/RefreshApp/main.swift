import AppKit
import RefreshCore

// Menu bar app: runs the keeper all the time, plus scan, save, diagnose and start-at-login from the menu.
// Scans run on the main thread and pump events themselves (see `wait`), like a modal dialog.

func log(_ s: String) { print("\(Date().formatted(date: .omitted, time: .standard)) \(s)") }
func hz(_ m: CGDisplayMode?) -> String { m.map { "\($0.pixelWidth)x\($0.pixelHeight) @ \(Int($0.refreshRate.rounded()))Hz" } ?? "?" }

enum LoginAgent {
    static let label = "com.devgoswami.refresh"
    static let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents/\(label).plist")
    static var installed: Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Takes effect at next login; this running copy keeps going either way.
    static func set(_ on: Bool) throws {
        guard on else { return try FileManager.default.removeItem(at: url) }
        let logFile = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Refresh.log").path
        let plist: [String: Any] = [
            "Label": label, "ProgramArguments": [Bundle.main.executablePath!], "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false], // restart after a crash, not after Quit
            "StandardOutPath": logFile, "StandardErrorPath": logFile,
        ]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
    }
}

final class App: NSObject, NSMenuDelegate {
    let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    var keeper: Keeper?

    override init() {
        super.init()
        status.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Refresh")
        status.menu = NSMenu()
        status.menu?.delegate = self
        startKeeper()
    }

    func startKeeper() {
        keeper?.stop()
        do {
            keeper = Keeper(profiles: try Profile.load(), log: log)
            keeper?.start()
        } catch { show("Cannot read saved setups", "\(Profile.url.path)\n\(error)") }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let online = Display.online()
        for d in online where !d.isBuiltin {
            let name = d.av?.edid?.name ?? "Display \(d.id)"
            menu.addItem(withTitle: "\(name): \(hz(d.mode))\(d.hdrAvailable && d.hdr ? " HDR" : "")", action: nil, keyEquivalent: "")
            add(menu, "Find fastest refresh for \(name)…", #selector(scan)).representedObject = d.key
        }
        let saved = (try? Profile.load())?.contains { $0.keys == Set(online.map(\.key)) } ?? false
        menu.addItem(withTitle: saved ? "Setup saved; kept after replug and sleep" : "No saved setup for these displays", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(menu, "Save Current Setup", #selector(save))
        add(menu, "Diagnose…", #selector(diagnose))
        add(menu, "Start at Login", #selector(toggleLogin)).state = LoginAgent.installed ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Refresh", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let i = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func scan(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? DisplayKey, let d = Display.find(key) else { return }
        let before = Profile.current(), hdr = d.hdrAvailable && d.hdr, name = d.av?.edid?.name ?? "Display"
        guard ask("Find the fastest refresh for \(name)?", "Takes about a minute. Your monitors will blink. Rotation and layout are put back.\(hdr ? " HDR stays on." : "")") else { return }
        keeper?.stop() // it would re-inject the saved EDID mid-scan
        status.button?.isEnabled = false
        defer { status.button?.isEnabled = true; startKeeper() }
        do {
            let r = try Scanner(key: key, log: log).run(hdr: hdr)
            let want = hdr ? r.hdrCeiling ?? r.factoryMax : r.ceiling
            if let d = Display.find(key), let m = d.modes(width: r.width, height: r.height).first(where: { Int($0.refreshRate.rounded()) == want }) {
                d.set(m)
                DisplayEvents.shared.settle(quiet: 1)
                if hdr { wait(3) { d.hdrAvailable }; d.hdr = true }
            }
            let summary = "\(name) now runs at \(want)Hz\(hdr ? " with HDR" : ""). Fastest: \(r.ceiling)Hz\(r.hdrCeiling.map { ", with HDR \($0)Hz" } ?? ""). It was \(r.factoryMax)Hz."
            if confirm(summary) { try Profile.current().save(); log("kept and saved") } else { try before.restore(); log("reverted") }
        } catch { show("Scan failed", "\(error)") }
    }

    @objc func save() {
        do { try Profile.current().save(); startKeeper() } catch { show("Save failed", "\(error)") }
    }

    @objc func diagnose() {
        let g = Diagnosis.run()
        show(g.findings.isEmpty ? "No problems found" : "\(g.findings.count) problem\(g.findings.count == 1 ? "" : "s") found", g.report)
    }

    @objc func toggleLogin() {
        do { try LoginAgent.set(!LoginAgent.installed) } catch { show("Cannot change Start at Login", "\(error)") }
    }

    /// 15s keep/revert, so a mode the monitor cannot show reverts by itself.
    // note: the dialog opens on the main display (menu bar screen), assumed to be one that still works
    func confirm(_ summary: String) -> Bool {
        let a = alert("Keep this refresh rate?", "")
        a.addButton(withTitle: "Keep")
        a.addButton(withTitle: "Revert")
        var left = 15
        a.informativeText = "\(summary)\n\nReverting in \(left)s."
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            left -= 1
            a.informativeText = "\(summary)\n\nReverting in \(left)s."
            if left <= 0 { NSApp.abortModal() }
        }
        RunLoop.main.add(t, forMode: .modalPanel)
        defer { t.invalidate() }
        return a.runModal() == .alertFirstButtonReturn
    }

    func ask(_ title: String, _ text: String) -> Bool {
        let a = alert(title, text)
        a.addButton(withTitle: "Start")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func show(_ title: String, _ text: String) { alert(title, text).runModal() }

    func alert(_ title: String, _ text: String) -> NSAlert {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        return a
    }
}

setvbuf(stdout, nil, _IOLBF, 0) // line-buffered so the LaunchAgent log stays current
guard AVService.available else { fatalError("private IOAVService API missing on this macOS") }
NSApplication.shared.setActivationPolicy(.accessory)
let app = App()
NSApp.run()
