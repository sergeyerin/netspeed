import Darwin
import Foundation

/// Shared machinery: a ring of recent measurements and statistics over them.
final class RTTSeries {
    private(set) var samples: [Double?] = []
    private let limit = 20

    func add(_ rtt: Double?) {
        samples.append(rtt)
        if samples.count > limit { samples.removeFirst(samples.count - limit) }
    }

    func reset() { samples.removeAll() }

    var isEmpty: Bool { samples.isEmpty }
    var last: Double? { samples.last ?? nil }
    var successful: [Double] { samples.compactMap { $0 } }
    var best: Double? { successful.min() }
    var average: Double? {
        let s = successful
        return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
    }

    /// Jitter as the mean spread between neighbouring samples — this is what
    /// makes a mobile link's "breathing" visible.
    var jitter: Double? {
        let s = successful
        guard s.count > 1 else { return nil }
        let diffs = zip(s.dropFirst(), s).map { abs($0 - $1) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    var lossPercent: Int { lossPercent(last: samples.count) }

    /// Statistics over the tail of the series.
    ///
    /// The verdict is about the link right now, so it looks at a short window.
    /// Over the full ring a burst of failures — a network switch, say — would
    /// keep the indicator red for minutes after everything recovered.
    func average(last count: Int) -> Double? {
        let s = samples.suffix(count).compactMap { $0 }
        return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
    }

    func lossPercent(last count: Int) -> Int {
        let window = samples.suffix(count)
        guard !window.isEmpty else { return 0 }
        return Int(round(Double(window.filter { $0 == nil }.count) / Double(window.count) * 100))
    }
}

// MARK: - Latency to the gateway (radio link health)

/// Pings the access point, showing the radio link apart from the internet path.
///
/// ICMP is the primary method: on macOS a SOCK_DGRAM socket with IPPROTO_ICMP
/// opens without root, and routers — including a phone in hotspot mode — answer
/// echo requests. Where ICMP is filtered, it falls back to TCP handshake timing.
final class GatewayProbe {
    enum Method: String {
        case icmp = "ICMP"
        case tcp = "TCP"
    }

    let series = RTTSeries()
    private(set) var host: String?
    private(set) var method: Method = .icmp
    private let queue = DispatchQueue(label: "netspeed.rtt.gateway", qos: .utility)
    private var busy = false
    private var seq: UInt16 = 0
    private var icmpFailures = 0

    func setHost(_ h: String?) {
        guard h != host else { return }
        host = h
        series.reset()
        method = .icmp
        icmpFailures = 0
    }

    func probe(completion: @escaping () -> Void) {
        guard !busy, let host else { return }
        busy = true
        seq &+= 1
        let seq = self.seq
        let method = self.method
        queue.async { [weak self] in
            let rtt = method == .icmp
                ? ICMPPing.measure(host: host, timeout: 2, seq: seq)
                : TCPRTT.measure(host: host, port: 80, timeout: 2, maxPlausible: 0.8)
            DispatchQueue.main.async {
                guard let self else { return }
                self.series.add(rtt)
                if self.method == .icmp {
                    // Three failures in a row most likely means ICMP is filtered here.
                    self.icmpFailures = rtt == nil ? self.icmpFailures + 1 : 0
                    if self.icmpFailures >= 3 {
                        self.method = .tcp
                        self.series.reset()
                    }
                }
                self.busy = false
                completion()
            }
        }
    }
}

enum ICMPPing {
    private static let ident = UInt16.random(in: 1...UInt16.max)
    private static let magic: [UInt8] = Array("netspeed-probe!!".utf8)

    static func measure(host: String, timeout: Double, seq: UInt16) -> Double? {
        var addr = sockaddr_in()
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var packet: [UInt8] = [8, 0, 0, 0,
                               UInt8(ident >> 8), UInt8(ident & 0xFF),
                               UInt8(seq >> 8), UInt8(seq & 0xFF)]
        packet += magic
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)

        let start = Date()
        let sent = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == packet.count else { return nil }

        var buf = [UInt8](repeating: 0, count: 512)
        // Replies for other sockets can land here, so read until ours or timeout.
        while true {
            let left = timeout - Date().timeIntervalSince(start)
            guard left > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(left * 1000)) == 1 else { return nil }
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return nil }
            let elapsed = Date().timeIntervalSince(start)
            // The kernel may hand the packet over with its IP header attached.
            let offset = (buf[0] >> 4) == 4 ? Int(buf[0] & 0x0F) * 4 : 0
            guard n >= offset + 8 else { continue }
            let type = buf[offset]
            let replySeq = UInt16(buf[offset + 6]) << 8 | UInt16(buf[offset + 7])
            if type == 0, replySeq == seq { return elapsed }
            if type == 3 { return nil }   // destination unreachable
        }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return UInt16(~sum & 0xFFFF)
    }
}

enum TCPRTT {
    /// `maxPlausible` filters out the SYN retransmit artefact: when a host drops
    /// packets silently, the answer arrives a second later and that is no longer
    /// a network latency figure.
    static func measure(host: String, port: UInt16, timeout: Double, maxPlausible: Double = .infinity) -> Double? {
        // Numeric addresses connect directly: even for a literal, getaddrinfo spins
        // up the name resolution machinery and costs noticeable CPU when repeated.
        var a4 = sockaddr_in()
        guard inet_pton(AF_INET, host, &a4.sin_addr) == 1 else { return nil }
        a4.sin_family = sa_family_t(AF_INET)
        a4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a4.sin_port = port.bigEndian

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var flags = fcntl(fd, F_GETFL, 0)
        flags |= O_NONBLOCK
        _ = fcntl(fd, F_SETFL, flags)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        let t0 = Date()
        let rc = withUnsafePointer(to: &a4) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return Date().timeIntervalSince(t0) }
        guard errno == EINPROGRESS else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return nil }
        let elapsed = Date().timeIntervalSince(t0)
        guard elapsed <= maxPlausible else { return nil }
        var err: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &size) == 0 else { return nil }
        // A refused connection is an answer too: the time to the RST is the RTT.
        if err == 0 || err == ECONNREFUSED || err == ECONNRESET { return elapsed }
        return nil
    }
}

// MARK: - Latency to the internet (the real path, VPN and proxies included)

/// Times a short HTTP request to a connectivity-check endpoint.
///
/// HTTP rather than TCP to some address: with a VPN or a local proxy in play, a
/// handshake with 1.1.1.1:443 terminates on this very machine and reports a fake
/// couple of milliseconds. An HTTP request travels the whole real path. As a
/// bonus, any answer other than 204 means a captive portal.
final class InternetProbe {
    struct Target {
        var title: String
        var url: URL
        var expects204: Bool
    }

    static let targets: [Target] = [
        Target(title: "Cloudflare", url: URL(string: "http://cp.cloudflare.com/generate_204")!, expects204: true),
        Target(title: "Google", url: URL(string: "http://connectivitycheck.gstatic.com/generate_204")!, expects204: true),
        Target(title: "Apple", url: URL(string: "http://captive.apple.com/hotspot-detect.html")!, expects204: false),
    ]

    let series = RTTSeries()
    private(set) var captivePortal = false
    private(set) var target: Target = InternetProbe.targets[0]
    private var busy = false

    /// One session for the whole run: the connection is reused, so from the
    /// second measurement on this times a clean round trip, like ping does.
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 4
        c.httpMaximumConnectionsPerHost = 1
        c.httpShouldSetCookies = false
        c.httpAdditionalHeaders = ["Cache-Control": "no-cache"]
        return URLSession(configuration: c)
    }()

    func setTarget(_ t: Target) {
        guard t.title != target.title else { return }
        target = t
        series.reset()
        captivePortal = false
    }

    func probe(completion: @escaping () -> Void) {
        guard !busy else { return }
        busy = true
        let t = target
        var req = URLRequest(url: t.url)
        req.httpMethod = "GET"
        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let t0 = Date()
        session.dataTask(with: req) { [weak self] data, response, error in
            let elapsed = Date().timeIntervalSince(t0)
            let http = response as? HTTPURLResponse
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if error != nil || http == nil {
                    self.series.add(nil)
                } else {
                    self.series.add(elapsed)
                    if t.expects204 {
                        self.captivePortal = http?.statusCode != 204 || (data?.isEmpty == false)
                    } else {
                        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        self.captivePortal = !body.contains("Success")
                    }
                }
                completion()
            }
        }.resume()
    }

    func reset() {
        series.reset()
        captivePortal = false
        // Drop pooled connections: after a network change the kept-alive socket
        // points at a path that no longer exists and the next probe just fails.
        session.flush {}
    }
}

// MARK: - Overall link verdict

enum LinkVerdict: Equatable {
    case offline, portal, awful, slow, medium, good, unknown

    /// Judged by internet latency, loss and the throughput actually reached.
    /// On a mobile link, RTT reacts to a change of technology faster than
    /// anything else available from a Mac, while the peak rate rules out the
    /// case of "quick to answer but capped at a few hundred kilobits".
    /// How many recent samples the verdict is based on — one minute of probing.
    static let window = 6

    static func evaluate(internet: InternetProbe, peakDown: Double, online: Bool) -> LinkVerdict {
        guard online else { return .offline }
        if internet.captivePortal { return .portal }
        let s = internet.series
        guard !s.isEmpty else { return .unknown }
        let loss = s.lossPercent(last: window)
        if loss >= 60 { return .offline }
        guard let rtt = s.average(last: window) else { return .offline }
        let ms = rtt * 1000
        if ms > 900 || loss >= 40 { return .awful }
        if ms > 400 || loss >= 20 { return .slow }
        if ms > 180 { return .medium }
        if peakDown > 0, peakDown < 60_000, ms > 90 { return .medium }
        return .good
    }
}
