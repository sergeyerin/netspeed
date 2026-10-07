import Foundation

/// Who on this Mac is using the network, and how hard.
///
/// The numbers come from `nettop`, which ships with macOS and needs no
/// privileges. Reading them directly would mean NetworkStatistics.framework —
/// private, undeclared, and the sort of thing that takes an app down on an OS
/// update. A short-lived subprocess, started only while the menu is open, buys
/// the same figures for a cost nobody can feel.
enum ProcessTraffic {
    struct Entry {
        let name: String
        let pid: Int32
        let bytesIn: Double          // per second
        let bytesOut: Double

        var total: Double { bytesIn + bytesOut }
    }

    enum Failure: Error {
        case unavailable             // no nettop on this system
        case noSamples               // it ran but said nothing useful
    }

    /// Rates over `seconds`, highest first.
    ///
    /// `nettop` reports running totals, so a single sample says what a process
    /// has transferred since it started — which is history, not what is
    /// happening now. Two samples a second apart give the rate, and the call
    /// therefore takes about that long. It runs off the main thread for exactly
    /// that reason.
    static func sample(seconds: Int = 2, completion: @escaping (Result<[Entry], Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try measure(seconds: seconds) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func measure(seconds: Int) throws -> [Entry] {
        let tool = URL(fileURLWithPath: "/usr/bin/nettop")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw Failure.unavailable
        }

        let task = Process()
        task.executableURL = tool
        // -P groups by process rather than by connection, -x gives plain
        // numbers instead of human-readable ones, -L prints a fixed number of
        // samples and exits rather than running until killed.
        task.arguments = ["-P", "-x", "-L", String(max(2, seconds)), "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { throw Failure.noSamples }
        return rates(from: text)
    }

    /// Output is one block per sample, each introduced by its own header line.
    /// Everything is cumulative, so the rate is the difference between the
    /// first block and the last, spread over the samples between them.
    static func rates(from text: String) -> [Entry] {
        var blocks: [[String: (Double, Double)]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(",bytes_in") {
                blocks.append([:])
                continue
            }
            guard !blocks.isEmpty else { continue }
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                  let bytesIn = Double(parts[1]), let bytesOut = Double(parts[2])
            else { continue }
            blocks[blocks.count - 1][String(parts[0])] = (bytesIn, bytesOut)
        }

        guard blocks.count >= 2, let first = blocks.first, let last = blocks.last else { return [] }
        let span = Double(blocks.count - 1)

        var entries: [Entry] = []
        for (key, totals) in last {
            let before = first[key] ?? (0, 0)
            let rateIn = (totals.0 - before.0) / span
            let rateOut = (totals.1 - before.1) / span
            // A process that started mid-sample has no earlier total to
            // subtract, and counters only ever climb — so anything negative is
            // a process that went away and came back on the same name.
            guard rateIn >= 0, rateOut >= 0 else { continue }
            guard rateIn + rateOut >= 1_024 else { continue }
            let (name, pid) = split(key)
            guard !isObserver(name) else { continue }
            entries.append(Entry(name: name, pid: pid, bytesIn: rateIn, bytesOut: rateOut))
        }
        return entries.sorted { $0.total > $1.total }
    }

    /// nettop labels a row `name.pid`, and plenty of process names contain dots
    /// of their own, so the split is from the right.
    private static func split(_ key: String) -> (String, Int32) {
        guard let dot = key.lastIndex(of: "."), let pid = Int32(key[key.index(after: dot)...]) else {
            return (key, 0)
        }
        return (String(key[..<dot]), pid)
    }

    /// Processes that carry other processes' traffic rather than making their
    /// own. Counting them alongside the rest double-counts, and someone reading
    /// the list has no way to know that from the name.
    ///
    /// Matched on the executable name: a VPN's tunnel process and a
    /// virtualiser's NAT daemon both show up as the heaviest user on the
    /// machine while neither is downloading anything.
    static func isCarrier(_ name: String) -> Bool {
        let carriers = ["prl_naptd", "vmnet-natd", "com.docker.vpnkit", "utun",
                        "Tunnel", "TunnelProvider", "NEIKEv2Provider", "nesessionmanager"]
        return carriers.contains { name.localizedCaseInsensitiveContains($0) }
    }

    /// The measuring tool itself, which exists for the length of the sample and
    /// for no other reason. Listing it would be reporting the act of looking.
    private static func isObserver(_ name: String) -> Bool {
        name == "nettop"
    }
}
