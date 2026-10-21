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

    private let maxExponent = 3
    private let stepDownRatio = 0.85  // hysteresis, keeps the unit from flickering

    /// Forgets the scale it had settled on.
    ///
    /// The scale persists between calls on purpose — that is the hysteresis —
    /// so switching modes has to clear it, or the old unit survives until the
    /// rate happens to cross a boundary.
    func reset() { exponent = 1 }

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
            exponent = 1
        }
        let base = unit.base
        let value = max(0, unit.value(fromBytesPerSecond: bytesPerSecond))

        // Bytes are allowed as the bottom step unless the scale is pinned.
        //
        // The floor used to be kilo, which made an idle link read "0 KB/s" —
        // a quiet lie, since something is nearly always trickling. Three
        // significant figures make the honest reading narrower than the lie
        // was: "412 B/s".
        let floor = pinned ? 1 : 0
        if pinned {
            exponent = 1
        } else if value > 0 {
            let atCurrentScale = value / pow(base, Double(exponent))
            if atCurrentScale >= base, exponent < maxExponent {
                exponent += 1
            } else if atCurrentScale < stepDownRatio, exponent > floor {
                exponent -= 1
            }
        }
        // Nothing moving holds the scale where the traffic left it. Allowed to
        // step, a gap in a megabyte download walks the unit down through
        // kilobytes to "0.0 B/s" — a reading that answers a question nobody
        // asked, in a unit that has nothing to do with what was happening a
        // second ago. "0 MB/s" says the same nothing against the right scale.
        //
        // A trickle still steps it down: this holds only on an exact zero, and
        // a few hundred bytes a second is not one.
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
        // Three columns, which is every reading this can produce once the unit
        // is free to follow it: the scale steps at the base, so the figure is
        // always between 1 and 999. Under ten it spends the third column on a
        // tenth — 1.2, 9.8 — because that is the decade where a tenth is a
        // tenth of the value rather than a thousandth.
        //
        // Four columns were needed only because the unit could not step down
        // to bytes and the figure had to stretch to cover the gap.
        //
        // Pinned to kilobytes the figure runs to six — 125000 KB/s on a
        // gigabit link — and a field that overflows is worse than a wide one.
        // Three columns for the whole part and a tenth, always.
        //
        // The tenth used to come and go — below ten it was there, above ten it
        // was not, and zero had neither — so the figure changed shape as well
        // as value and the eye kept re-reading it. Always present, it is a
        // fixed mark the reading hangs on; the menu bar sets it a size down,
        // the way it does the unit, so it informs without competing.
        let number = pinned
            ? String(format: "%6.0f", scaled)
            : String(format: "%5.1f", scaled)
        // The suffix is padded too, because "B/s" is a character shorter than
        // "KB/s" and the item would jump a character wide every time the scale
        // crossed a kilobyte — which, on an idle link, is constantly.
        let widest = unit.suffixes.map(\.count).max() ?? 0
        let suffix = unit.suffixes[exponent]
        let spaced = padded
            ? String(repeating: " ", count: widest - suffix.count) + suffix
            : suffix
        return (padded ? number : number.trimmingCharacters(in: .whitespaces))
            + " " + spaced
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
