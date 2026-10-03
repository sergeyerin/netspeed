import CoreWLAN
import Foundation
import ObjectiveC.runtime

/// Asks the tethering phone to turn its hotspot back on.
///
/// This is the thing the Wi-Fi menu does when a phone is listed under Personal
/// Hotspot and you click it. It is not a Wi-Fi join: when the phone loses
/// cellular service it shuts the hotspot down entirely, so there is no network
/// left to rejoin and no amount of reconnecting on this side will help. The
/// entry still showing in the menu comes over Continuity, not from a beacon,
/// and selecting it sends the phone a request to switch the hotspot on again.
///
/// CoreWLAN carries that request — `connectToTetherDevice:remember:error:` on
/// CWInterface — but does not declare it in its headers. So every call is
/// guarded by `responds(to:)` and the feature simply reports itself unavailable
/// if a future macOS drops it, rather than taking the app down with it.
enum HotspotConnect {
    private static let connectSelector = NSSelectorFromString("connectToTetherDevice:remember:error:")
    private static let lastJoinedSelector = NSSelectorFromString("lastTetherDeviceJoined")

    /// `(self, _cmd, device, remember, error)` returning a C99 bool — the
    /// signature the runtime reports as `B36@0:8@16B24^@28`.
    private typealias ConnectFunction = @convention(c)
        (AnyObject, Selector, AnyObject, Bool, UnsafeMutablePointer<NSError?>?) -> Bool

    private static var interface: CWInterface? { CWWiFiClient.shared().interface() }

    /// The phone this Mac last tethered to, if macOS still remembers it. Present
    /// even while connected to something else entirely, which is what makes an
    /// unattended reconnect possible at all.
    static func knownPhone() -> (device: AnyObject, name: String)? {
        guard let interface, interface.responds(to: lastJoinedSelector),
              let device = interface.perform(lastJoinedSelector)?.takeUnretainedValue() else { return nil }
        let name = (device.value(forKey: "_deviceName") as? String) ?? "hotspot"
        return (device, name)
    }

    static var isSupported: Bool {
        guard let interface else { return false }
        return interface.responds(to: connectSelector) && interface.responds(to: lastJoinedSelector)
    }

    enum Outcome {
        case asked(String)          // the phone was asked; the join follows if it agrees
        case noPhoneKnown
        case unsupported
        case failed(String)
    }

    /// Sends the request. Returning means the phone was asked, not that the Mac
    /// is on the hotspot: the phone has to enable it and the join happens after.
    @discardableResult
    static func connect() -> Outcome {
        guard let interface, isSupported else { return .unsupported }
        guard let phone = knownPhone() else { return .noPhoneKnown }
        guard let method = class_getInstanceMethod(type(of: interface), connectSelector) else {
            return .unsupported
        }
        let call = unsafeBitCast(method_getImplementation(method), to: ConnectFunction.self)

        var error: NSError?
        let ok = withUnsafeMutablePointer(to: &error) { pointer in
            call(interface, connectSelector, phone.device, true, pointer)
        }
        if ok { return .asked(phone.name) }
        return .failed(error?.localizedDescription ?? "the phone did not answer")
    }
}
