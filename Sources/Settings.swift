import Foundation

enum TitleMode: String, CaseIterable {
    case both        // two lines: down and up
    case downOnly    // download only
    case sum         // combined rate on one line
    case withPing    // down/up plus latency
    case hidden      // indicator only, no numbers at all

    var title: String {
        switch self {
        case .both: return "Down and up (2 lines)"
        case .downOnly: return "Download only"
        case .sum: return "Combined (1 line)"
        case .withPing: return "Down, up and latency"
        case .hidden: return "Indicator only (no numbers)"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private enum K {
        static let interval = "interval"
        static let unit = "unit"
        static let pinned = "pinnedInterface"
        static let titleMode = "titleMode"
        static let latency = "latencyEnabled"
        static let target = "internetTarget"
        static let indicator = "indicatorStyle"
        static let externalIP = "showExternalIP"
        static let updates = "checkForUpdates"
    }

    init() {
        d.register(defaults: [
            K.interval: 1.0,
            K.unit: RateUnit.bytes.rawValue,
            K.titleMode: TitleMode.both.rawValue,
            K.latency: true,
            K.target: "Cloudflare",
            K.indicator: IndicatorStyle.bars.rawValue,
            K.externalIP: true,
            K.updates: true,
        ])
    }

    var interval: Double {
        get { d.double(forKey: K.interval) }
        set { d.set(newValue, forKey: K.interval) }
    }

    var unit: RateUnit {
        get { RateUnit(rawValue: d.string(forKey: K.unit) ?? "") ?? .bytes }
        set { d.set(newValue.rawValue, forKey: K.unit) }
    }

    /// nil means the interface is chosen automatically.
    var pinnedInterface: String? {
        get { d.string(forKey: K.pinned) }
        set { newValue == nil ? d.removeObject(forKey: K.pinned) : d.set(newValue, forKey: K.pinned) }
    }

    var titleMode: TitleMode {
        get { TitleMode(rawValue: d.string(forKey: K.titleMode) ?? "") ?? .both }
        set { d.set(newValue.rawValue, forKey: K.titleMode) }
    }

    var latencyEnabled: Bool {
        get { d.bool(forKey: K.latency) }
        set { d.set(newValue, forKey: K.latency) }
    }

    /// Which endpoint the internet latency probe uses (see InternetProbe.targets).
    var internetTarget: String {
        get { d.string(forKey: K.target) ?? "Cloudflare" }
        set { d.set(newValue, forKey: K.target) }
    }

    /// Whether the menu asks an outside service for the address the world sees.
    var showExternalIP: Bool {
        get { d.bool(forKey: K.externalIP) }
        set { d.set(newValue, forKey: K.externalIP) }
    }

    /// Whether to ask GitHub once a day whether a newer release exists.
    var checkForUpdates: Bool {
        get { d.bool(forKey: K.updates) }
        set { d.set(newValue, forKey: K.updates) }
    }

    /// What to draw left of the numbers: bars, a short label, both or nothing.
    var indicatorStyle: IndicatorStyle {
        get { IndicatorStyle(rawValue: d.string(forKey: K.indicator) ?? "") ?? .bars }
        set { d.set(newValue.rawValue, forKey: K.indicator) }
    }
}
