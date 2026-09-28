import AppKit

/// Colors that adapt to a light or dark menu bar.
///
/// The system yellow and orange are hard to read on a light menu bar, so every
/// level carries its own pair of values instead.
enum Tone {
    case good, warn, alert, bad, info, neutral

    var color: NSColor {
        switch self {
        case .good: return Tone.dynamic(light: Tone.rgb(0.11, 0.54, 0.24), dark: Tone.rgb(0.19, 0.82, 0.35))
        case .warn: return Tone.dynamic(light: Tone.rgb(0.70, 0.37, 0.00), dark: Tone.rgb(1.00, 0.62, 0.04))
        case .alert: return Tone.dynamic(light: Tone.rgb(0.69, 0.19, 0.00), dark: Tone.rgb(1.00, 0.48, 0.29))
        case .bad: return Tone.dynamic(light: Tone.rgb(0.76, 0.07, 0.12), dark: Tone.rgb(1.00, 0.27, 0.23))
        case .info: return Tone.dynamic(light: Tone.rgb(0.04, 0.36, 0.83), dark: Tone.rgb(0.39, 0.82, 1.00))
        case .neutral: return .secondaryLabelColor
        }
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
}

extension LinkVerdict {
    /// Only states that need words get them.
    ///
    /// Quality is carried by the bars and the color alone: labelling a measured
    /// estimate `LTE` or `E` made it look like a cellular technology the Mac had
    /// read off the modem, which it is not. The real technology appears here
    /// only when a tethering phone actually reports it.
    var marker: String {
        switch self {
        case .offline: return "OFF"
        case .portal: return "WEB"
        case .good, .medium, .slow, .awful, .unknown: return ""
        }
    }

    /// How many of the four bars are filled.
    var level: Int {
        switch self {
        case .good: return 4
        case .medium: return 3
        case .slow: return 2
        case .awful: return 1
        case .offline, .portal, .unknown: return 0
        }
    }

    var tone: Tone {
        switch self {
        case .good: return .good
        case .medium: return .warn
        case .slow: return .alert
        case .awful, .offline: return .bad
        case .portal: return .info
        case .unknown: return .neutral
        }
    }

    /// The verdict in one word — what the menu leads with.
    var quality: String {
        switch self {
        case .good: return "Good"
        case .medium: return "Fair"
        case .slow: return "Slow"
        case .awful: return "Awful"
        case .offline: return "Offline"
        case .portal: return "Sign-in needed"
        case .unknown: return "Measuring…"
        }
    }

    /// What the link behaves like, for the parenthetical after the verdict.
    /// Always a comparison, never a claim about the technology in use.
    var comparison: String {
        switch self {
        case .good: return "LTE/5G-like"
        case .medium: return "weak 4G-like"
        case .slow: return "3G-like"
        case .awful: return "EDGE-like"
        case .offline, .portal, .unknown: return ""
        }
    }

    static let all: [LinkVerdict] = [.good, .medium, .slow, .awful, .offline, .portal, .unknown]
}

/// What the indicator draws. The label is either the measured estimate or the
/// technology the tethering phone reports — the drawing code does not care which.
struct LinkState: Equatable {
    var badge: String       // menu bar label, empty unless there is a fact to state
    var level: Int          // filled bars, 0...4
    var tone: Tone
    var quality: String     // "Awful"
    var detail: String      // "EDGE-like" or "phone: 5G"; may be empty

    init(badge: String, level: Int, tone: Tone, quality: String, detail: String) {
        self.badge = badge
        self.level = max(0, min(4, level))
        self.tone = tone
        self.quality = quality
        self.detail = detail
    }

    init(_ verdict: LinkVerdict) {
        self.init(badge: verdict.marker, level: verdict.level, tone: verdict.tone,
                  quality: verdict.quality, detail: verdict.comparison)
    }

    /// "Awful (phone: 5G)" — the verdict first, the qualifier in brackets.
    var summary: String {
        detail.isEmpty ? quality : "\(quality) (\(detail))"
    }
}

enum IndicatorStyle: String, CaseIterable {
    case bars
    case barsAndBadge
    case none

    var title: String {
        switch self {
        case .bars: return "Signal bars"
        case .barsAndBadge: return "Bars and network type"
        case .none: return "No indicator"
        }
    }
}

enum Indicator {
    private static let font = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    private static let barCount = 4
    private static let barWidth: CGFloat = 2.5
    private static let barGap: CGFloat = 1.5
    private static let barsWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
    private static let innerGap: CGFloat = 3.5
    private static let height: CGFloat = 16

    /// Widest label of everything that can be shown — the measured estimates and
    /// every cellular technology name. The box is reserved up front so the image
    /// always has one size; otherwise the status item would resize whenever the
    /// state changed and shove the numbers sideways.
    private static let badgeBox: CGFloat = {
        let labels = LinkVerdict.all.map(\.marker) + CellularType.allLabels
        return labels
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
    }()

    /// The picture is drawn by hand: a bar scale plus a label as one colored unit.
    ///
    /// It is deliberately not a template image — the system would repaint that
    /// monochrome and the color would lose its meaning. The contents are produced
    /// inside a drawing block, so dynamic colors follow theme changes on their own.
    static func image(for state: LinkState, style: IndicatorStyle) -> NSImage? {
        guard style != .none else { return nil }
        let showBars = true
        // An empty label reserves no room: with nothing to say, the indicator
        // shrinks to the bars instead of leaving a gap where a word would be.
        let showBadge = style == .barsAndBadge && !state.badge.isEmpty
        let width = (showBars ? barsWidth : 0)
            + (showBars && showBadge ? innerGap : 0)
            + (showBadge ? badgeBox : 0)

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let color = state.tone.color
            var x: CGFloat = 0

            if showBars {
                let heights: [CGFloat] = [4, 6.5, 9, 11.5]
                for i in 0..<barCount {
                    // Unfilled bars stay as a pale ghost of the same color, so the
                    // scale reads as "this many out of four".
                    (i < state.level ? color : color.withAlphaComponent(0.22)).setFill()
                    let r = NSRect(x: x, y: 2.5, width: barWidth, height: heights[i])
                    NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
                    x += barWidth + barGap
                }
                x += innerGap - barGap
            }

            if showBadge {
                let text = state.badge as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = text.size(withAttributes: attrs)
                text.draw(at: NSPoint(x: x, y: (height - size.height) / 2 + 0.5), withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
