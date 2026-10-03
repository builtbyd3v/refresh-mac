import AppKit

/// Puts a saved profile back whenever displays change: re-injects the EDID macOS drops on replug and sleep,
/// then refresh rate, HDR, rotation and layout. Fully idle between display events. Needs a running NSApp loop.
public final class Keeper {
    let profiles: [Profile]
    let log: (String) -> Void
    private var timer: Timer?
    private var burstEnd = Date.distantPast, lastInject = Date.distantPast
    private var busy = false, acted = false, laidOut = false
    private var done: Set<DisplayKey> = []  // set up on this connection; manual changes after that are left alone
    private var injects: [DisplayKey: (count: Int, at: Date)] = [:]

    public init(profiles: [Profile], log: @escaping (String) -> Void = { print($0) }) {
        self.profiles = profiles
        self.log = log
    }

    public func start() {
        DisplayEvents.shared.onChange = { [weak self] in self?.burst() }
        burst()
    }

    /// Check every 0.25s until done or 20s after the latest display event, then stop the timer.
    private func burst() {
        burstEnd = Date().addingTimeInterval(20)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self, !self.busy else { return } // Placement.restore pumps events, which can fire this timer again
            self.busy = true
            let ok = self.step()
            self.busy = false
            guard ok || Date() > self.burstEnd else { return }
            t.invalidate()
            self.timer = nil
            if self.acted || !ok { self.log(ok ? "done" : "gave up until the next display event") }
            self.acted = false
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// One pass over the matching profile. True when nothing is left to do.
    func step() -> Bool {
        let online = Display.online(), keys = Set(online.map(\.key))
        done.formIntersection(keys)
        let settled = Date().timeIntervalSince(lastInject) > 8 // an injected monitor blinks offline for a few seconds
        guard let p = profiles.first(where: { $0.keys == keys }) else { laidOut = false; return settled }

        var ready = true
        for m in p.monitors {
            guard let d = online.first(where: { $0.key == m.key }) else { continue }
            if let want = m.edid {
                guard let av = d.av, let cur = av.edid else { ready = false; continue } // AV service not up yet
                if cur != want { // fresh plug-in or wake dropped the override
                    done.remove(m.key)
                    laidOut = false
                    ready = false
                    var n = injects[m.key] ?? (0, .distantPast)
                    if Date().timeIntervalSince(n.at) > 60 { n.count = 0 }
                    // Max 3 tries a minute: a rejected EDID would otherwise blink the monitor forever.
                    guard n.count < 3, Date().timeIntervalSince(n.at) > 3 else { continue }
                    n = (n.count + 1, Date())
                    injects[m.key] = n
                    lastInject = n.at
                    acted = true
                    log("\(m.key): inject EDID (try \(n.count)/3): 0x\(String(av.setEDID(want), radix: 16))")
                    continue
                }
                injects[m.key] = nil
            }
            if done.contains(m.key) { continue }
            if d.mode.map(m.matches) != true {
                guard let mode = d.modes.first(where: m.matches), d.set(mode) else { ready = false; continue } // modes not listed yet
                acted = true
                log("\(m.key): \(m.pixelWidth)x\(m.pixelHeight)@\(m.hz)Hz")
            }
            if d.hdr != m.hdr {
                guard !m.hdr || d.hdrAvailable else { ready = false; continue }
                d.hdr = m.hdr
                acted = true
                log("\(m.key): HDR \(m.hdr ? "on" : "off")")
            }
            done.insert(m.key)
        }
        guard ready else { return false }
        if !laidOut {
            if Set(Placement.current()) != Set(p.placements) {
                Placement.restore(p.placements)
                acted = true
                log("rotation and layout restored")
            }
            laidOut = true
        }
        return settled
    }
}
