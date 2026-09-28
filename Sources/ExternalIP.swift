import Foundation

/// Looks up the address the outside world sees, together with its country.
///
/// Cloudflare's `cdn-cgi/trace` answers both in one plain-text request and needs
/// no key, so a single round trip covers what two lookup services would. With a
/// VPN or proxy in the path this reports the exit node, which is exactly the
/// question worth answering.
final class ExternalIP {
    struct Result {
        var address: String
        var countryCode: String?   // two-letter code, e.g. "NL"
        var at: Date

        /// "1.2.3.4 (🇳🇱 NL)" — the flag is derived from the code, not fetched.
        var display: String {
            guard let code = countryCode, code.count == 2 else { return address }
            return "\(address) (\(ExternalIP.flag(code)) \(code))"
        }
    }

    private(set) var result: Result?
    private(set) var fetching = false

    /// Beyond this the answer is treated as stale and looked up again.
    private let maxAge: TimeInterval = 300

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 5
        return URLSession(configuration: c)
    }()

    var isStale: Bool {
        guard let result else { return true }
        return Date().timeIntervalSince(result.at) > maxAge
    }

    /// Forgets the answer — the address almost certainly changed with the network.
    func invalidate() {
        result = nil
    }

    func fetchIfNeeded(completion: @escaping () -> Void) {
        guard !fetching, isStale else { return }
        fetching = true
        var request = URLRequest(url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session.dataTask(with: request) { [weak self] data, response, _ in
            let parsed = Self.parse(data: data, response: response)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                if let parsed { self.result = parsed }
                completion()
            }
        }.resume()
    }

    /// The body is `key=value` lines; only `ip` and `loc` are of interest.
    private static func parse(data: Data?, response: URLResponse?) -> Result? {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data, let text = String(data: data, encoding: .utf8) else { return nil }
        var address: String?
        var country: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "ip": address = String(parts[1])
            case "loc": country = String(parts[1])
            default: break
            }
        }
        guard let address, !address.isEmpty, address.count < 64 else { return nil }
        let code = country.flatMap { $0.count == 2 ? $0.uppercased() : nil }
        return Result(address: address, countryCode: code, at: Date())
    }

    /// Regional indicator symbols sit at a fixed offset from the Latin letters.
    private static func flag(_ code: String) -> String {
        let base: UInt32 = 0x1F1E6 - UInt32(("A" as UnicodeScalar).value)
        var flag = ""
        for letter in code.uppercased().unicodeScalars {
            guard ("A"..."Z").contains(letter), let scalar = UnicodeScalar(base + letter.value) else { return code }
            flag.unicodeScalars.append(scalar)
        }
        return flag
    }
}
