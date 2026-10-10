import CoreLocation
import Foundation

/// Permission to read the name of the Wi-Fi network.
///
/// macOS treats the name as a location: knowing which network a Mac is on
/// places it on a map about as well as GPS would, so `CWInterface.ssid()` is
/// gated behind Location access. Without it both CoreWLAN and `ipconfig
/// getsummary` return the literal string `<redacted>`.
///
/// The app asks for nothing on launch and this does not change that. The
/// request happens when someone chooses it from the menu, having read what it
/// is for — a network meter that wants your location on first run is a
/// reasonable thing to be suspicious of, and the only thing lost by refusing
/// is one row of text.
final class NetworkName: NSObject, CLLocationManagerDelegate {
    static let shared = NetworkName()

    private let manager = CLLocationManager()
    private var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    enum State {
        case granted
        case refused         // denied or restricted; only Settings can undo it
        case available       // never asked
    }

    var state: State {
        switch manager.authorizationStatus {
        case .authorized, .authorizedAlways: return .granted
        case .denied, .restricted: return .refused
        case .notDetermined: return .available
        @unknown default: return .available
        }
    }

    /// Shows the system prompt. Does nothing once the answer is on record:
    /// macOS asks once and afterwards only Settings can change it.
    func request(then changed: @escaping () -> Void) {
        guard state == .available else { return changed() }
        onChange = changed
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let changed = onChange
        onChange = nil
        DispatchQueue.main.async { changed?() }
    }

    /// Where to go after refusing, since the prompt will not come back.
    static let settingsHint = "System Settings → Privacy & Security → Location Services"
}
