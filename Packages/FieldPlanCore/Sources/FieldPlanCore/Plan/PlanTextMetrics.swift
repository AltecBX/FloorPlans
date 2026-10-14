import Foundation

/// Estimated text widths for plan layout.
///
/// The plan generator has to decide, before any renderer exists, whether a room
/// label fits between two walls. It cannot ask a font — the same scene is drawn
/// by SwiftUI, Core Graphics, SVG and DXF — so it uses the Helvetica advance
/// widths below, which match what the renderers actually produce to within a
/// percent or two:
///
///     "BEDROOM" 5.167 estimated / 5.166 measured
///     "LIVING ROOM" 6.668 / 6.666      "5' 0\" × 6' 0\"" 5.012 / 5.018
///
/// A single average per character would be wrong by a factor of two between a
/// room name and a dimension string — wide enough to drop labels that fit and
/// keep labels that overrun their wall onto a client's drawing.
public enum PlanTextMetrics {

    /// Advance width of one character as a fraction of the text height.
    /// Unlisted characters fall back to a conservative width for their class.
    static func width(of character: Character) -> Double {
        switch character {
        // Uppercase
        case "A", "B", "E", "K", "P", "S", "V", "X", "Y": return 0.667
        case "C", "D", "H", "N", "R", "U": return 0.722
        case "F", "T", "Z": return 0.611
        case "G", "O", "Q": return 0.778
        case "I": return 0.278
        case "J": return 0.500
        case "L": return 0.556
        case "M": return 0.833
        case "W": return 0.944
        // Lowercase
        case "a", "b", "d", "e", "g", "h", "n", "o", "p", "q", "u": return 0.556
        case "c", "k", "s", "v", "x", "y", "z": return 0.500
        case "f", "t": return 0.278
        case "i", "j", "l": return 0.222
        case "m": return 0.833
        case "r": return 0.333
        case "w": return 0.722
        // Digits and common symbols
        case "0"..."9", "#", "$": return 0.556
        case " ", ".", ",", ":", ";", "/", "·", "-": return 0.278
        case "'", "’": return 0.191
        case "\"", "”": return 0.355
        case "(", ")", "[", "]", "{", "}", "*": return 0.333
        case "×", "+", "=", "<", ">", "–": return 0.584
        case "—": return 1.000
        default:
            if character.isUppercase { return 0.778 }
            if character.isLowercase { return 0.556 }
            if character.isNumber { return 0.556 }
            return 0.556
        }
    }

    /// Width of `text` if it were drawn at height 1 — multiply by the text
    /// height to get plan meters.
    public static func units(_ text: String) -> Double {
        text.reduce(0.0) { $0 + width(of: $1) }
    }

    /// Estimated drawn width of `text` at `height`, in plan meters.
    public static func width(_ text: String, height: Double) -> Double {
        units(text) * height
    }

    /// The largest text height at which `text` still fits `maxWidth`.
    /// Returns `nil` for text with no drawable characters.
    public static func heightToFit(_ text: String, maxWidth: Double) -> Double? {
        let units = units(text)
        guard units > 1e-9 else { return nil }
        return maxWidth / units
    }
}
