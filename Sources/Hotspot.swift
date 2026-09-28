import Foundation
import SystemConfiguration

/// Cellular technology the tethering phone reports.
///
/// The raw values come from the enum ControlCenter uses to label a Personal
/// Hotspot in the Wi-Fi menu (`WiFiHotspotNetworkType`): its cases are declared
/// in the order below, and its jump table maps 6 to LTE and 7 to 5G.
enum CellularType: Int {
    case other = 0
    case oneX = 1
    case gprs = 2
    case edge = 3
    case threeG = 4
    case fourG = 5
    case lte = 6
    case fiveG = 7

    var label: String {
        switch self {
        case .other: return "—"
        case .oneX: return "1x"
        case .gprs: return "GPRS"
        case .edge: return "EDGE"
        case .threeG: return "3G"
        case .fourG: return "4G"
        case .lte: return "LTE"
        case .fiveG: return "5G"
        }
    }

    static let allLabels: [String] = (0...7).compactMap { CellularType(rawValue: $0)?.label }

    /// Roughly what this technology can deliver, for the times the reported type
    /// and the measured behaviour disagree.
    var expectation: String {
        switch self {
        case .other: return "unknown technology"
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

    static func read(interface bsd: String) -> TetherDevice? {
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
                            networkType: CellularType(rawValue: device.type) ?? .other)
    }
}
