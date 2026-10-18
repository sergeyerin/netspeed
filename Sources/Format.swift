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

    /// Forgets the scale it had settled on.
    ///
    /// The scale persists between calls on purpose — that is the hysteresis —
    /// so switching modes has to clear it, or the old unit survives until the
    /// rate happens to cross a boundary.
    func reset() { exponent = minExponent }

    /// `pinned` keeps the unit at kilo however fast the link goes.
    ///
    /// Scaling is what a reader has to undo: 1.2 MB/s and 980 KB/s are a
    /// second apart on a busy link and comparing them means converting one in
    /// your head. Pinned, the figure only ever grows. It costs width — a
    /// gigabit link reaches six digits — which is why it is a choice and not
    /// the default.
    func format(_ bytesPerSecond: Double, unit: RateUnit,
                padded: Bool = true, pinned: Bool = false) -> String {
        if unit != lastUnit {
            lastUnit = unit
            exponent = minExponent
        }
        let base = unit.base
        let value = max(0, unit.value(fromBytesPerSecond: bytesPerSecond))

        if pinned {
            exponent = minExponent
        } else {
            let atCurrentScale = value / pow(base, Double(exponent))
            if atCurrentScale >= base, exponent < maxExponent {
                exponent += 1
            } else if atCurrentScale < stepDownRatio, exponent > minExponent {
                exponent -= 1
            }
        }
        let scaled = value / pow(base, Double(exponent))

        // Four columns wide, so the width never changes.
        //
        // Whole numbers in kilobytes: there the tenths changed every tick
        // without deciding anything — nobody acts on 52.9 against 53.1 KB/s,
        // and a flickering last digit is the sort of movement the eye keeps
        // going back to. Below half a kilobyte a second this reads 0 KB/s,
        // the honest summary of nothing happening; the unit never steps below
        // kilo by design, so there was no finer reading to lose.
        //
        // Megabytes keep a tenth while it fits. Dropping it there costs a
        // whole decade of resolution — 1.1 and 1.9 MB/s both read "1" — and
        // that decade is where a fast link spends its time. Past 99.95 the
        // figure needs all four columns and the tenth goes, which matters
        // less: the step from 114 to 115 MB/s is a tenth of a per cent.
        //
        // Four columns and not five: the unit steps up at the base, so the
        // number only ever reaches four figures in the top decade — 1023 MB/s.
        // Six columns when pinned, because a gigabit link reaches 125000 KB/s
        // and a field that overflows is worse than a wide one.
        let number = pinned
            ? String(format: "%6.0f", scaled)
            : (exponent >= 2 && scaled < 99.95
                ? String(format: "%4.1f", scaled)
                : String(format: "%4.0f", scaled))
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
