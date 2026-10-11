import Foundation
import SystemConfiguration

/// Cellular technology the tethering phone reports.
///
/// The raw values come from the enum ControlCenter uses to label a Personal
/// Hotspot in the Wi-Fi menu (`WiFiHotspotNetworkType`), which is undocumented:
/// the class carrying it appears in CoreWLAN's symbol table and in none of its
/// public headers. The numbers mean whatever observation says they mean.
///
/// Two are settled, each by catching the system's own Wi-Fi menu naming the
/// device in the same second the raw value was read:
///
///   * 4 is 3G — seen 11 Oct 2026
///   * 7 is LTE — seen 10 Oct 2026
///
/// ControlCenter holds seven labels in this order: 1x, GPRS, EDGE, 3G, 4G,
/// LTE, 5G. Those two anchors leave one more value between 3G and LTE than
/// there are labels for, so one case carries no label at all. It is placed
/// where a real technology sits unnamed — HSPA, between 3G and 4G — but that
/// is inference, not evidence, and so is everything here except 4 and 7.
///
/// Which is why `CellularLog` records every value this app ever sees. The next
/// disagreement between the badge and the Wi-Fi menu should not need a fresh
/// investigation, only the log and a glance at the menu.
enum CellularType: Int {
    case none = 0
    case oneX = 1
    case gprs = 2
    case edge = 3
    case threeG = 4
    case unnamed = 5          // no label in ControlCenter; HSPA, most likely
    case fourG = 6
    case lte = 7
    case fiveG = 8

    /// Every raw value the app sees passes through here, so the log is a
    /// complete record and not a sample.
    static func seen(_ raw: Int) -> CellularType {
        let type = CellularType(rawValue: raw) ?? .none
        CellularLog.record(raw: raw, shownAs: type.label)
        return type
    }

    /// What a phone writes in its own status bar, not what the technology is
    /// called. Someone glancing at the menu bar is comparing it against the
    /// phone in their hand, and `E` beside `EDGE` is one more thing to work
    /// out. It also costs less room, which on this row is the whole budget.
    var label: String {
        switch self {
        case .none, .unnamed: return "—"
        case .oneX: return "1x"
        case .gprs: return "G"
        case .edge: return "E"
        case .threeG: return "3G"
        case .fourG: return "4G"
        case .lte: return "LTE"
        case .fiveG: return "5G"
        }
    }

    /// The full name, for the places with room to spell it out.
    var fullName: String {
        switch self {
        case .none: return "unknown"
        case .unnamed: return "unnamed by macOS"
        case .oneX: return "1xRTT"
        case .gprs: return "GPRS"
        case .edge: return "EDGE"
        case .threeG: return "3G"
        case .fourG: return "4G"
        case .lte: return "LTE"
        case .fiveG: return "5G"
        }
    }

    /// Roughly what this technology can deliver, for the times the reported type
    /// and the measured behaviour disagree.
    var expectation: String {
        switch self {
        case .none: return "unknown technology"
        case .unnamed: return "a type macOS does not name — most likely HSPA"
        case .oneX, .gprs: return "2G, tens of kbit/s"
        case .edge: return "2.5G, up to ~200 kbit/s"
        case .threeG: return "3G, a few Mbit/s"
        case .fourG: return "4G"
        case .lte: return "LTE, tens of Mbit/s"
        case .fiveG: return "5G, up to hundreds of Mbit/s"
        }
    }
}

/// What the tethering iPhone or iPad tells the Mac about itself.
struct TetherDevice {
    var name: String
    var signalBars: Int        // cellular bars on the phone, 0...4
    var battery: Int           // percent
    var networkType: CellularType

    static let maxBars = 4
}

/// Reads the hotspot state macOS keeps for the Wi-Fi menu.
///
/// When a phone shares its connection, the Wi-Fi menu shows its cellular bars,
/// battery and network type. That data lands in the dynamic store under
/// `State:/Network/Interface/<bsd>/AirPort` as a `LastTetherDevice` blob — a
/// keyed archive of CoreWLAN's private `CWTetherDevice`. The archive is plain
/// NSCoding, so a stand-in class decodes it without touching private API, and
/// the values track the phone live.
/// One read of the Wi-Fi interface state, shared by everything that needs it.
///
/// The dictionary carries both the hotspot blob and the raw SSID, and copying it
/// costs a fraction of a millisecond — far less than asking CoreWLAN, which
/// takes about ten and is too expensive to do on every tick.
enum AirPort {
    private static var store: SCDynamicStore? = {
        SCDynamicStoreCreate(nil, "NetSpeed" as CFString, nil, nil)
    }()
    private static var cache: (iface: String, dict: [String: Any]?, at: Date)?

    static func state(of bsd: String) -> [String: Any]? {
        if let cache, cache.iface == bsd, Date().timeIntervalSince(cache.at) < 0.4 { return cache.dict }
        let dict = store.flatMap {
            SCDynamicStoreCopyValue($0, "State:/Network/Interface/\(bsd)/AirPort" as CFString) as? [String: Any]
        }
        cache = (bsd, dict, Date())
        return dict
    }

    /// Raw SSID bytes — enough to tell one network from another without the cost
    /// of resolving the name, and unchanged when roaming between access points.
    static func ssidData(of bsd: String) -> Data? {
        state(of: bsd)?["SSID"] as? Data
    }
}

enum HotspotReader {
    /// The class is private to CoreWLAN, so the archive is decoded into a
    /// look-alike registered under the same name.
    @objc(NetSpeedTetherDecoy)
    private final class Decoy: NSObject, NSCoding {
        let signal: Int
        let battery: Int
        let type: Int
        let name: String

        init?(coder: NSCoder) {
            // The numbers are archived as NSNumber objects, not inline integers:
            // decodeInteger(forKey:) rejects them as "not an integer number".
            func number(_ key: String) -> Int {
                coder.decodeObject(of: NSNumber.self, forKey: key)?.intValue ?? 0
            }
            signal = number("_signalStrength")
            battery = number("_batteryLife")
            type = number("_networkType")
            name = (coder.decodeObject(of: NSString.self, forKey: "_deviceName") as String?) ?? ""
        }

        func encode(with coder: NSCoder) {}
    }

    /// The phone's own readout, from whichever source still has it.
    ///
    /// CoreWLAN's live object is asked first. It is both fresher and more
    /// durable than the copy in the dynamic store: the stored one was showing a
    /// battery level an hour out of date while the live object had the current
    /// one, and then macOS dropped the stored key altogether on a rejoin while
    /// the live object carried on answering. Reading only the archive meant the
    /// phone's row simply vanished.
    static func read(interface bsd: String) -> TetherDevice? {
        live() ?? archived(interface: bsd)
    }

    /// Straight off CWTetherDevice, by key — the ivars are `_networkType` and
    /// friends, and the object is the same one the Wi-Fi menu is drawing from.
    private static func live() -> TetherDevice? {
        guard let device = HotspotConnect.knownPhone()?.device else { return nil }
        func number(_ key: String) -> Int { (device.value(forKey: key) as? NSNumber)?.intValue ?? 0 }
        let type = number("_networkType")
        let name = (device.value(forKey: "_deviceName") as? String) ?? ""
        // Nothing useful read means the object is there but empty, and the
        // archive may still hold a usable snapshot.
        guard type != 0 || !name.isEmpty else { return nil }
        return TetherDevice(name: name,
                            signalBars: max(0, min(TetherDevice.maxBars, number("_signalStrength"))),
                            battery: max(0, min(100, number("_batteryLife"))),
                            networkType: CellularType.seen(type))
    }

    private static func archived(interface bsd: String) -> TetherDevice? {
        guard let data = AirPort.state(of: bsd)?["LastTetherDevice"] as? Data else { return nil }

        let device: Decoy?
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            unarchiver.setClass(Decoy.self, forClassName: "CWTetherDevice")
            device = unarchiver.decodeObject(of: Decoy.self, forKey: NSKeyedArchiveRootObjectKey)
            unarchiver.finishDecoding()
        } catch {
            return nil
        }
        guard let device else { return nil }

        return TetherDevice(name: device.name,
                            signalBars: max(0, min(TetherDevice.maxBars, device.signal)),
                            battery: max(0, min(100, device.battery)),
                            networkType: CellularType.seen(device.type))
    }
}
