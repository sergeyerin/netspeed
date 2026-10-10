import Foundation

/// Everything the panel needs to know, as plain values.
///
/// Gathered by the delegate from the live monitors, and by the screenshot
/// generator from invented ones. That is the point of its existing: the rows
/// are then built once, in one place, and a picture of the menu cannot show a
/// layout the menu no longer has.
struct MenuFacts {
    var unit: RateUnit = .bytes
    var peak: Speed = Speed(down: 0, up: 0)
    var sessionDown: UInt64 = 0
    var sessionUp: UInt64 = 0
    var uptime: TimeInterval = 0

    var latencyEnabled = true
    var internetTarget = "Cloudflare"
    var internet = RTTSeries()
    var captivePortal = false
    var gatewayHost: String?
    var gateway = RTTSeries()
    var gatewayMethod = "ICMP"

    var tether: TetherDevice?

    /// The interface carrying traffic, nil when nothing is.
    var interfaceBSD: String?
    var interfaceName = "Wi-Fi"
    var wifi: WiFiLink?
    var ipv4: String?
    var ipv6: String?
    var gatewayAddress: String?
    /// "utun4 over en0" when a VPN is carrying the traffic.
    var tunnel: String?
    /// Shown when on a Personal Hotspot that reports no cellular type of its own.
    var hotspotWithoutType = false

    var showExternalIP = true
    var externalIP: String?
    var externalIPLookingUp = false
}

enum MenuContent {
    /// Two sizes, because the panel was answering two different questions with
    /// one list. "Is my connection all right" wants six rows; "why is it
    /// behaving like this" wants the radio, the addresses and the route, and
    /// pays for them in a wall of text that buries the first answer. The short
    /// form is the default and the long one is a click away.
    static func lines(_ f: MenuFacts, detailed: Bool) -> [PanelView.Line] {
        detailed ? detailedLines(f) : summaryLines(f)
    }

    /// Everything that answers "how is it going", and nothing that answers
    /// "how is it wired".
    private static func summaryLines(_ f: MenuFacts) -> [PanelView.Line] {
        var lines: [PanelView.Line] = []
        lines.append(.kv("Peak (1 min)", "↓ \(Fmt.rate(f.peak.down, unit: f.unit))   ↑ \(Fmt.rate(f.peak.up, unit: f.unit))"))
        lines.append(.kv("Session", "↓ \(Fmt.size(f.sessionDown))   ↑ \(Fmt.size(f.sessionUp))"))

        if f.latencyEnabled {
            lines.append(.kv("Internet", reading(f.internet)))
            // Loss belongs in the short form: it is the one number that says a
            // link is failing while every other figure still looks healthy.
            lines.append(.note("   " + stats(f.internet), .neutral))
            if f.gatewayHost != nil {
                lines.append(.kv("Access point", reading(f.gateway)))
            }
        }

        // One line for the phone rather than a section: on a hotspot this is
        // the whole reason the app is open, and it compresses without loss.
        if let t = f.tether {
            lines.append(.kv("Phone", "\(t.networkType.fullName) · \(t.signalBars)/\(TetherDevice.maxBars) · \(t.battery)%"))
        }
        lines.append(contentsOf: networkLines(f))
        lines.append(contentsOf: externalIPLines(f))
        lines.append(contentsOf: warningLines(f))
        return lines
    }

    /// The short form plus the diagnostics: radio, addresses, route.
    private static func detailedLines(_ f: MenuFacts) -> [PanelView.Line] {
        var lines: [PanelView.Line] = []
        lines.append(.kv("Peak (1 min)", "↓ \(Fmt.rate(f.peak.down, unit: f.unit))   ↑ \(Fmt.rate(f.peak.up, unit: f.unit))"))
        lines.append(.kv("Session", "↓ \(Fmt.size(f.sessionDown))   ↑ \(Fmt.size(f.sessionUp))"))
        lines.append(.kv("Uptime", Fmt.duration(f.uptime)))

        if f.latencyEnabled {
            lines.append(.section("LATENCY"))
            lines.append(.kv("Internet (\(f.internetTarget))", reading(f.internet)))
            lines.append(.note("   " + stats(f.internet), .neutral))
            if f.gatewayHost != nil {
                lines.append(.kv("Access point", reading(f.gateway)))
                lines.append(.note("   over \(f.gatewayMethod) · " + stats(f.gateway), .neutral))
            }
        }

        if let t = f.tether {
            lines.append(.section("HOTSPOT PHONE"))
            lines.append(.kv("Device", t.name.isEmpty ? "—" : t.name))
            lines.append(.bars("Cellular", t.signalBars, TetherDevice.maxBars,
                               "\(t.networkType.fullName) · \(t.signalBars)/\(TetherDevice.maxBars)"))
            lines.append(.kv("Phone battery", "\(t.battery)%"))
            lines.append(.note("Reported by the phone itself — \(t.networkType.expectation)", .neutral))
        }

        lines.append(.section("CONNECTION"))
        if let bsd = f.interfaceBSD {
            lines.append(.kv(f.interfaceName, bsd))
            if let w = f.wifi {
                lines.append(.kv("Network", w.ssid ?? "name unavailable"))
                // Two sections, one phone: without saying so, the Wi-Fi below
                // reads as a second network that happens to be nearby, when it
                // is the hop to the phone named above.
                if let t = f.tether {
                    lines.append(.note("   this Wi-Fi is the hop to \(t.name), not another network", .neutral))
                }
                lines.append(.bars("Wi-Fi signal", w.quality.bars, 5, "\(w.rssi) dBm · SNR \(w.snr) dB"))
                lines.append(.kv("Link rate", "\(Int(w.txRate)) Mbit/s"))
                lines.append(.kv("Channel", "\(w.channel) · \(w.band) · \(w.width)"))
                lines.append(.note("   \(w.phy) · \(w.security) · noise \(w.noise) dBm", .neutral))
            }
            if let v4 = f.ipv4 {
                lines.append(.kv("IP", v4))
                if f.hotspotWithoutType {
                    lines.append(.note("Personal Hotspot: the cellular type is only visible on the phone", .neutral))
                }
            }
            if let gw = f.gatewayAddress { lines.append(.kv("Gateway", gw)) }
            if let v6 = f.ipv6 { lines.append(.kv("IPv6", v6)) }
        } else {
            lines.append(.note("No active interface found", .bad))
        }
        if let t = f.tunnel { lines.append(.kv("VPN", t)) }
        lines.append(contentsOf: externalIPLines(f))
        lines.append(contentsOf: warningLines(f))
        return lines
    }

    /// Which network this is — the one connection fact the short form keeps.
    private static func networkLines(_ f: MenuFacts) -> [PanelView.Line] {
        guard f.interfaceBSD != nil else { return [.note("No active interface found", .bad)] }
        let name = f.wifi?.ssid ?? f.interfaceName
        guard let tunnel = f.tunnel else { return [.kv("Network", name)] }
        // A VPN changes where the traffic comes out, which is worth a line even
        // in the short form — it explains an external IP that looks wrong.
        return [.kv("Network", name), .kv("VPN", tunnel)]
    }

    private static func externalIPLines(_ f: MenuFacts) -> [PanelView.Line] {
        guard f.showExternalIP else { return [] }
        if let ip = f.externalIP { return [.kv("External IP", ip)] }
        return [.kv("External IP", f.externalIPLookingUp ? "looking up…" : "unavailable")]
    }

    /// Conditional and rare, so they survive into the short form: each one
    /// explains something the figures above cannot.
    private static func warningLines(_ f: MenuFacts) -> [PanelView.Line] {
        var lines: [PanelView.Line] = []
        if f.captivePortal {
            lines.append(.note("This network requires signing in through a browser", .info))
        }
        // If "the internet" answers faster than the gateway, it is not the internet.
        if f.latencyEnabled, f.gatewayHost != nil,
           (f.internet.average ?? .infinity) < (f.gateway.average ?? 0) {
            lines.append(.note("Answers faster than the access point — likely a local proxy", .alert))
        }
        return lines
    }

    private static func reading(_ s: RTTSeries) -> String {
        s.last.map { Fmt.ms($0) } ?? (s.isEmpty ? "measuring…" : "no reply")
    }

    /// Short form for the menu panel, full form for the copied summary.
    static func stats(_ s: RTTSeries, full: Bool = false) -> String {
        var parts: [String] = []
        if let a = s.average { parts.append("avg \(Fmt.ms(a))") }
        if full, let b = s.best { parts.append("best \(Fmt.ms(b))") }
        if let j = s.jitter { parts.append("jitter \(Fmt.ms(j))") }
        parts.append("loss \(s.lossPercent)%")
        return parts.joined(separator: " · ")
    }
}
