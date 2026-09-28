import Foundation

enum RateUnit: String {
    case bytes   // KB/s, MB/s
    case bits    // Kb/s, Mb/s

    var title: String { self == .bytes ? "Bytes (MB/s)" : "Bits (Mb/s)" }
    var base: Double { self == .bytes ? 1024 : 1000 }
    var suffixes: [String] {
        self == .bytes ? ["B/s", "KB/s", "MB/s", "GB/s"] : ["b/s", "Kb/s", "Mb/s", "Gb/s"]
    }

    func value(fromBytesPerSecond bytes: Double) -> Double {
        self == .bits ? bytes * 8 : bytes
    }
}

/// Fixed-width rate formatter for the menu bar.
///
/// Two things make a plain adaptive format jump around: the unit flips between
/// B/s and KB/s on every idle second, and the digit count changes with the
/// value, so the status item keeps resizing and shifts everything next to it.
/// Here the unit never drops below kilo, switches up only past the full base
/// and back down only below 85% of it, and the number is padded to a constant
/// width — so the string is always exactly the same length.
final class RateFormatter {
    private var exponent = 1          // 1 = kilo, 2 = mega, 3 = giga
    private var lastUnit: RateUnit?

    private let minExponent = 1
    private let maxExponent = 3
    private let stepDownRatio = 0.85  // hysteresis, keeps the unit from flickering

    func format(_ bytesPerSecond: Double, unit: RateUnit, padded: Bool = true) -> String {
        if unit != lastUnit {
            lastUnit = unit
            exponent = minExponent
        }
        let base = unit.base
        let value = max(0, unit.value(fromBytesPerSecond: bytesPerSecond))

        var scaled = value / pow(base, Double(exponent))
        if scaled >= base, exponent < maxExponent {
            exponent += 1
        } else if scaled < stepDownRatio, exponent > minExponent {
            exponent -= 1
        }
        scaled = value / pow(base, Double(exponent))

        // Both branches produce five characters, so the width never changes.
        let number = scaled >= 99.95
            ? String(format: "%5.0f", scaled)
            : String(format: "%5.1f", scaled)
        return (padded ? number : number.trimmingCharacters(in: .whitespaces))
            + " " + unit.suffixes[exponent]
    }
}

enum Fmt {
    /// Adaptive format for details, where a stable width does not matter.
    static func rate(_ bytesPerSecond: Double, unit: RateUnit) -> String {
        let value = unit.value(fromBytesPerSecond: bytesPerSecond)
        let (v, index) = scale(value, base: unit.base, steps: unit.suffixes.count)
        return "\(number(v)) \(unit.suffixes[index])"
    }

    /// Both units at once — for the detail rows and the copied summary.
    static func rateBoth(_ bytesPerSecond: Double) -> String {
        "\(rate(bytesPerSecond, unit: .bytes))  ·  \(rate(bytesPerSecond, unit: .bits))"
    }

    static func size(_ bytes: UInt64) -> String {
        let (v, index) = scale(Double(bytes), base: 1024, steps: 5)
        return "\(number(v)) \(["B", "KB", "MB", "GB", "TB"][index])"
    }

    static func ms(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%.2f s", seconds) : String(format: "%.0f ms", seconds * 1000)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    private static func scale(_ value: Double, base: Double, steps: Int) -> (Double, Int) {
        var v = max(0, value)
        var i = 0
        while v >= base, i < steps - 1 { v /= base; i += 1 }
        return (v, i)
    }

    /// At most three significant digits.
    private static func number(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}
