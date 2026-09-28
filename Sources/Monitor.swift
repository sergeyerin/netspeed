import Foundation

struct Speed {
    var down: Double = 0   // bytes per second
    var up: Double = 0
    var total: Double { down + up }
}

/// Computes per-interface rates and keeps a short history for the chart.
final class Monitor {
    private(set) var speed = Speed()
    private(set) var history: [Speed] = []
    private(set) var activity: [String: Double] = [:]   // bytes/s per interface, used for auto-pick
    private(set) var counters: [String: IfCounters] = [:]
    private(set) var sessionDown: UInt64 = 0
    private(set) var sessionUp: UInt64 = 0
    private(set) var startedAt = Date()
    private(set) var trackedInterface: String?

    let historyLimit = 120

    private var previous: [String: IfCounters] = [:]
    private var previousAt = Date()

    init() {
        previous = Kernel.counters()
        counters = previous
    }

    /// One polling tick. `pinned` is the manually chosen interface (nil = auto).
    func tick(pinned: String?) {
        let now = Date()
        let fresh = Kernel.counters()
        let dt = max(0.05, now.timeIntervalSince(previousAt))

        var act: [String: Double] = [:]
        for (name, c) in fresh {
            guard let p = previous[name] else { continue }
            let d = Kernel.delta(c.inBytes, p.inBytes) + Kernel.delta(c.outBytes, p.outBytes)
            act[name] = Double(d) / dt
        }
        activity = act
        counters = fresh

        let target = pinned ?? Interfaces.autoPick(counters: fresh, activity: act)
        if target != trackedInterface {
            // The interface changed — reset the totals, otherwise another link's
            // traffic would land in this session's counters.
            trackedInterface = target
            sessionDown = 0
            sessionUp = 0
            startedAt = now
            history.removeAll(keepingCapacity: true)
            speed = Speed()
        }

        if let name = target, let c = fresh[name], let p = previous[name] {
            let dDown = Kernel.delta(c.inBytes, p.inBytes)
            let dUp = Kernel.delta(c.outBytes, p.outBytes)
            sessionDown += dDown
            sessionUp += dUp
            speed = Speed(down: Double(dDown) / dt, up: Double(dUp) / dt)
        } else {
            speed = Speed()
        }

        history.append(speed)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }

        previous = fresh
        previousAt = now
    }

    var peak: Speed {
        Speed(down: history.map(\.down).max() ?? 0, up: history.map(\.up).max() ?? 0)
    }

    /// The maximum over the last `seconds` — what the link actually managed.
    func recentPeak(seconds: Int, interval: Double) -> Speed {
        let n = max(1, Int(Double(seconds) / max(0.1, interval)))
        let slice = history.suffix(n)
        return Speed(down: slice.map(\.down).max() ?? 0, up: slice.map(\.up).max() ?? 0)
    }

    var uptime: Double { Date().timeIntervalSince(startedAt) }
}
