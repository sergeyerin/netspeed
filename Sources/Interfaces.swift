import CoreWLAN
import Darwin
import Foundation
import SystemConfiguration

enum LinkKind {
    case wifi
    case hotspotUSB      // iPhone or iPad over cable
    case ethernet
    case tunnel          // VPN: utun / ipsec / ppp
    case bridge
    case other

    /// SF Symbol name for the menu.
    var symbol: String {
        switch self {
        case .wifi: return "wifi"
        case .hotspotUSB: return "iphone.gen3"
        case .ethernet: return "cable.connector"
        case .tunnel: return "lock.shield"
        case .bridge, .other: return "network"
        }
    }

    var title: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .hotspotUSB: return "iPhone USB"
        case .ethernet: return "Ethernet"
        case .tunnel: return "VPN tunnel"
        case .bridge: return "Bridge"
        case .other: return "Interface"
        }
    }
}

struct Interface {
    var bsd: String              // en0
    var displayName: String      // Wi-Fi
    var kind: LinkKind
    var isPhysical: Bool { kind != .tunnel && kind != .bridge }
}

enum Interfaces {
    /// Human-readable interface names from SystemConfiguration (Wi-Fi, iPhone USB,
    /// USB LAN...). The list rarely changes, so it is cached and refreshed on demand.
    private static var displayNames: [String: String] = [:]
    private static var wifiNames: Set<String> = []
    private static var loaded = false

    static func reload() {
        var names: [String: String] = [:]
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all {
                guard let bsd = SCNetworkInterfaceGetBSDName(i) as String? else { continue }
                names[bsd] = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
            }
        }
        displayNames = names
        wifiNames = Set((CWWiFiClient.shared().interfaces() ?? []).compactMap(\.interfaceName))
        loaded = true
    }

    static func describe(_ bsd: String, counters: IfCounters?) -> Interface {
        if !loaded { reload() }
        let display = displayNames[bsd] ?? bsd
        return Interface(bsd: bsd, displayName: display, kind: kind(bsd, display: display, counters: counters))
    }

    static func isWiFi(_ bsd: String) -> Bool {
        if !loaded { reload() }
        return wifiNames.contains(bsd)
    }

    private static func kind(_ bsd: String, display: String, counters: IfCounters?) -> LinkKind {
        if wifiNames.contains(bsd) { return .wifi }
        for prefix in ["utun", "ipsec", "ppp", "gpd", "tun", "tap", "wg"] where bsd.hasPrefix(prefix) {
            return .tunnel
        }
        if bsd.hasPrefix("bridge") { return .bridge }
        if display.localizedCaseInsensitiveContains("iPhone") || display.localizedCaseInsensitiveContains("iPad") {
            return .hotspotUSB
        }
        if let c = counters, c.type == UInt8(IFT_ETHER) { return .ethernet }
        if bsd.hasPrefix("en") { return .ethernet }
        return .other
    }

    /// Interfaces worth offering for monitoring: up, addressed, not housekeeping.
    static func candidates(counters: [String: IfCounters]) -> [Interface] {
        if !loaded { reload() }
        let skip = ["lo", "gif", "stf", "awdl", "llw", "anpi", "ap1", "XHC", "vmenet", "bridge1"]
        return counters.keys.compactMap { bsd -> Interface? in
            guard let c = counters[bsd], c.isUp, !c.isLoopback else { return nil }
            if skip.contains(where: { bsd.hasPrefix($0) }) { return nil }
            // Without an address an interface is useless for measuring: this drops
            // idle Thunderbolt ports, empty USB adapters and sleeping tunnels.
            let addrs = Kernel.addresses(of: bsd)
            guard !addrs.v4.isEmpty || !addrs.v6.isEmpty else { return nil }
            return describe(bsd, counters: c)
        }
        .sorted { ($0.isPhysical ? 0 : 1, $0.bsd) < ($1.isPhysical ? 0 : 1, $1.bsd) }
    }

    /// Picks the interface to measure automatically.
    ///
    /// The point is to measure the physical link. With a VPN up, the default
    /// route leads into a `utun`, yet the bytes still travel over Wi-Fi, where
    /// the tunnel's traffic is already counted — so tunnels are skipped.
    static func autoPick(counters: [String: IfCounters], activity: [String: Double]) -> String? {
        let routes = Kernel.defaultRoutes()
        if let physical = routes.first(where: { describe($0.interface, counters: counters[$0.interface]).isPhysical }) {
            return physical.interface
        }
        let cands = candidates(counters: counters).filter(\.isPhysical)
        if let busiest = cands.max(by: { (activity[$0.bsd] ?? 0) < (activity[$1.bsd] ?? 0) }),
           (activity[busiest.bsd] ?? 0) > 0 {
            return busiest.bsd
        }
        if let wifi = cands.first(where: { $0.kind == .wifi }) { return wifi.bsd }
        return cands.first?.bsd ?? routes.first?.interface
    }
}

/// A short signature of the system's proxy settings.
///
/// Some VPN clients never create an interface of their own — they only flip the
/// system proxy — so watching routes cannot see them come and go. The address
/// the outside world sees changes all the same, and that is reported in the
/// menu, so the proxy configuration counts as part of which network this is.
enum Proxies {
    private static let store = SCDynamicStoreCreate(nil, "NetSpeed.proxies" as CFString, nil, nil)

    static func signature() -> String {
        guard let store,
              let root = SCDynamicStoreCopyValue(store, "State:/Network/Global/Proxies" as CFString)
                  as? [String: Any] else { return "-" }

        // Only the switches and ports: the rest of the dictionary is noise, and
        // its key order is not stable enough to compare as a whole.
        func collect(_ dict: [String: Any], prefix: String) -> [String] {
            var parts = dict.keys.sorted()
                .filter { $0.hasSuffix("Enable") || $0.hasSuffix("Port") }
                .compactMap { key -> String? in
                    (dict[key] as? Int).map { "\(prefix)\(key)=\($0)" }
                }
            if let scoped = dict["__SCOPED__"] as? [String: Any] {
                for iface in scoped.keys.sorted() {
                    if let inner = scoped[iface] as? [String: Any] {
                        parts += collect(inner, prefix: "\(iface).")
                    }
                }
            }
            return parts
        }
        return collect(root, prefix: "").joined(separator: ",")
    }
}

// MARK: - Wi-Fi details

struct WiFiLink {
    var ssid: String?
    var bssid: String?
    var rssi: Int          // dBm
    var noise: Int         // dBm
    var txRate: Double     // Mbit/s — the link rate, not the internet speed
    var channel: Int
    var band: String
    var width: String
    var phy: String
    var security: String

    var snr: Int { rssi - noise }

    /// A rough but practical scale: RSSI tells whether the link carries at all.
    var quality: (bars: Int, text: String) {
        switch rssi {
        case ..<(-82): return (1, "very weak")
        case ..<(-75): return (2, "weak")
        case ..<(-67): return (3, "fair")
        case ..<(-57): return (4, "good")
        default: return (5, "excellent")
        }
    }
}

enum WiFiReader {
    /// A CoreWLAN query costs about 10 ms and the data is needed several times
    /// per tick, so the result is held for exactly the length of one tick.
    private static var linkCache: (iface: String, link: WiFiLink?, at: Date)?

    static func read(interface bsd: String) -> WiFiLink? {
        if let c = linkCache, c.iface == bsd, Date().timeIntervalSince(c.at) < 0.4 { return c.link }
        let link = fetch(interface: bsd)
        linkCache = (bsd, link, Date())
        return link
    }

    private static func fetch(interface bsd: String) -> WiFiLink? {
        guard Interfaces.isWiFi(bsd), let i = CWWiFiClient.shared().interface(withName: bsd),
              i.powerOn(), i.serviceActive() else { return nil }
        let ch = i.wlanChannel()
        // ssid()/bssid() need Location access; without it, fall back to ipconfig.
        let names = i.ssid() == nil ? Self.namesFromIPConfig(bsd) : (i.ssid(), i.bssid())
        return WiFiLink(ssid: i.ssid() ?? names.0,
                        bssid: i.bssid() ?? names.1,
                        rssi: i.rssiValue(),
                        noise: i.noiseMeasurement(),
                        txRate: i.transmitRate(),
                        channel: ch?.channelNumber ?? 0,
                        band: band(ch?.channelBand),
                        width: width(ch?.channelWidth),
                        phy: phy(i.activePHYMode()),
                        security: security(i.security()))
    }

    /// `ipconfig getsummary` reports the SSID without a TCC prompt. Called rarely:
    /// only when the network changes.
    private static var cache: (iface: String, ssid: String?, bssid: String?, at: Date)?

    static func namesFromIPConfig(_ bsd: String) -> (String?, String?) {
        if let c = cache, c.iface == bsd, Date().timeIntervalSince(c.at) < 10 { return (c.ssid, c.bssid) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
        p.arguments = ["getsummary", bsd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        var ssid: String?
        var bssid: String?
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("SSID :"), ssid == nil {
                    ssid = String(t.dropFirst("SSID :".count)).trimmingCharacters(in: .whitespaces)
                } else if t.hasPrefix("BSSID :"), bssid == nil {
                    bssid = String(t.dropFirst("BSSID :".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        } catch { /* ipconfig unavailable — carry on without the SSID */ }
        cache = (bsd, ssid, bssid, Date())
        return (ssid, bssid)
    }

    private static func band(_ b: CWChannelBand?) -> String {
        switch b {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return "—"
        }
    }

    private static func width(_ w: CWChannelWidth?) -> String {
        switch w {
        case .width20MHz: return "20 MHz"
        case .width40MHz: return "40 MHz"
        case .width80MHz: return "80 MHz"
        case .width160MHz: return "160 MHz"
        default: return "—"
        }
    }

    private static func phy(_ m: CWPHYMode) -> String {
        switch m {
        case .mode11a: return "802.11a"
        case .mode11b: return "802.11b"
        case .mode11g: return "802.11g"
        case .mode11n: return "802.11n (Wi-Fi 4)"
        case .mode11ac: return "802.11ac (Wi-Fi 5)"
        case .mode11ax: return "802.11ax (Wi-Fi 6)"
        default: return "—"
        }
    }

    private static func security(_ s: CWSecurity) -> String {
        switch s {
        case .none: return "open"
        case .WEP: return "WEP"
        case .wpaPersonal, .wpaPersonalMixed: return "WPA"
        case .wpa2Personal: return "WPA2"
        case .wpa3Personal, .wpa3Transition: return "WPA3"
        case .enterprise, .wpaEnterprise, .wpa2Enterprise, .wpa3Enterprise: return "Enterprise"
        default: return "—"
        }
    }
}
