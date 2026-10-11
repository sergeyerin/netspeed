import Foundation

/// A record of every cellular type a tethering phone has reported.
///
/// The enum behind these numbers is undocumented, so the table that names them
/// was assembled by catching macOS's own Wi-Fi menu labelling a device at the
/// moment the raw value was read. Two values are settled that way and the rest
/// are inference, which means the next disagreement is a matter of when rather
/// than whether.
///
/// This exists so that disagreement costs a glance instead of an investigation:
/// the raw value is already written down with the time, and all that is needed
/// is what the Wi-Fi menu said.
///
/// Only changes are written. A phone sitting on LTE for a day is one line.
enum CellularLog {
    static let path = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NetSpeed/cellular-types.log")

    private static var last: Int?
    private static let queue = DispatchQueue(label: "netspeed.cellular.log", qos: .utility)

    static func record(raw: Int, shownAs label: String) {
        guard raw != last else { return }
        last = raw
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  raw=\(raw)  shown=\(label)\n"
        queue.async {
            let directory = path.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: path) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: path)
            }
        }
    }
}
