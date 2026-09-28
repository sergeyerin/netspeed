import Foundation

/// Asks GitHub whether a newer release exists.
///
/// The release is already the one place the disk image lives, so it is also the
/// one place worth asking — a manifest on the site would be a second copy of the
/// same fact, free to disagree with the first. The unauthenticated API allows
/// sixty requests an hour per address; this uses one a day.
///
/// It only ever reports. Downloading and swapping the app in place would need a
/// developer certificate to be safe, and without one Gatekeeper would refuse the
/// result anyway, so the answer is a menu item pointing at the release page.
final class UpdateChecker {
    struct Release: Equatable {
        var version: String     // "1.3", without the tag's leading v
        var url: URL
    }

    private(set) var newer: Release?
    private(set) var lastChecked: Date?
    private(set) var checking = false

    private let current: [Int]
    private let endpoint = URL(string: "https://api.github.com/repos/sergeyerin/netspeed/releases/latest")!
    private let interval: TimeInterval = 24 * 60 * 60

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }()

    init(currentVersion: String) {
        current = UpdateChecker.parse(currentVersion)
    }

    var isDue: Bool {
        guard let lastChecked else { return true }
        return Date().timeIntervalSince(lastChecked) >= interval
    }

    func check(force: Bool = false, completion: @escaping () -> Void) {
        guard !checking, force || isDue else { return }
        checking = true
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [weak self] data, response, _ in
            let release = Self.parse(data: data, response: response)
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                // A failed check leaves the previous answer alone: a flaky
                // network should not retract an update that does exist.
                if let release {
                    self.lastChecked = Date()
                    self.newer = Self.parse(release.version) > self.current ? release : nil
                }
                completion()
            }
        }.resume()
    }

    private static func parse(data: Data?, response: URLResponse?) -> Release? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let link = json["html_url"] as? String, let url = URL(string: link) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty, version.count < 32 else { return nil }
        return Release(version: version, url: url)
    }

    /// "1.10" is newer than "1.9", so the parts are compared as numbers rather
    /// than as text.
    private static func parse(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }
}

private func > (lhs: [Int], rhs: [Int]) -> Bool {
    for i in 0..<max(lhs.count, rhs.count) {
        let l = i < lhs.count ? lhs[i] : 0
        let r = i < rhs.count ? rhs[i] : 0
        if l != r { return l > r }
    }
    return false
}
