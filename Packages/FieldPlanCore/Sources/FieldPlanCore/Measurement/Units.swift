import Foundation

/// Display unit systems. Internal geometry is ALWAYS meters at full
/// precision; these types only affect display and export formatting.
public enum UnitSystem: String, Codable, CaseIterable, Sendable {
    case feetInches
    case decimalFeet
    case meters
    case centimeters

    public var displayName: String {
        switch self {
        case .feetInches: return "Feet & Inches"
        case .decimalFeet: return "Decimal Feet"
        case .meters: return "Meters"
        case .centimeters: return "Centimeters"
        }
    }
}

/// Fractional-inch display precision. Raw value is the fraction denominator.
public enum FractionPrecision: Int, Codable, CaseIterable, Sendable {
    case inch = 1
    case half = 2
    case quarter = 4
    case eighth = 8
    case sixteenth = 16

    public var displayName: String {
        switch self {
        case .inch: return "Nearest 1\""
        case .half: return "Nearest 1/2\""
        case .quarter: return "Nearest 1/4\""
        case .eighth: return "Nearest 1/8\""
        case .sixteenth: return "Nearest 1/16\""
        }
    }
}

public enum UnitConstants {
    public static let metersPerInch = 0.0254
    public static let metersPerFoot = 0.3048
    public static let squareMetersPerSquareFoot = 0.09290304
    public static let cubicMetersPerCubicFoot = 0.028316846592
}

/// Formats lengths and areas for display. Rounding happens HERE only —
/// stored geometry is never rounded.
public struct UnitFormatter: Sendable {
    public var system: UnitSystem
    public var precision: FractionPrecision

    public init(system: UnitSystem = .feetInches, precision: FractionPrecision = .eighth) {
        self.system = system
        self.precision = precision
    }

    // MARK: Length

    /// Formats a length in meters for display, e.g. `12' 7 3/8"`.
    public func length(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        switch system {
        case .feetInches:
            return UnitFormatter.feetInchesString(meters: meters, denominator: precision.rawValue)
        case .decimalFeet:
            let feet = meters / UnitConstants.metersPerFoot
            return String(format: "%.2f ft", feet)
        case .meters:
            return String(format: "%.3f m", meters)
        case .centimeters:
            return String(format: "%.1f cm", meters * 100)
        }
    }

    /// Compact length used on dimension strings in drawings (no unit suffix
    /// beyond the tick marks for imperial).
    public func dimensionLabel(_ meters: Double) -> String {
        length(meters)
    }

    /// One side of a room-label size, in the tight form a floor plan uses:
    /// `12'5"`, `3.79 m`. Imperial rounds to the whole inch on purpose — an
    /// eighth on a room label is noise, and the room's real measurement lives
    /// in the model, not in this string.
    public func roomDimension(_ meters: Double) -> String {
        guard meters.isFinite else { return "—" }
        switch system {
        case .feetInches:
            let inches = Int((abs(meters) / UnitConstants.metersPerInch).rounded())
            let sign = meters < 0 ? "-" : ""
            return "\(sign)\(inches / 12)'\(inches % 12)\""
        case .decimalFeet:
            return String(format: "%.1f'", meters / UnitConstants.metersPerFoot)
        case .meters:
            return String(format: "%.2f m", meters)
        case .centimeters:
            return String(format: "%.0f cm", meters * 100)
        }
    }

    /// A room label's size line: `14'0" x 12'5"`, `4.28 m x 3.79 m`.
    /// The separator is a lowercase x, as drawn on floor plans, not a
    /// multiplication sign — it reads at label size and every font has it.
    public func roomDimensions(_ width: Double, _ depth: Double) -> String {
        "\(roomDimension(width)) x \(roomDimension(depth))"
    }

    // MARK: Area

    /// Formats an area in square meters, e.g. `142.5 sq ft`.
    public func area(_ squareMeters: Double) -> String {
        guard squareMeters.isFinite else { return "—" }
        switch system {
        case .feetInches, .decimalFeet:
            let sqft = squareMeters / UnitConstants.squareMetersPerSquareFoot
            return String(format: "%.1f sq ft", sqft)
        case .meters, .centimeters:
            return String(format: "%.2f m²", squareMeters)
        }
    }

    /// Area as it reads on a floor plan sheet: whole units, thousands
    /// separated — `1,455 sq ft`. The tenth of a square foot that `area`
    /// carries is right for a takeoff and wrong under a drawing.
    public func sheetArea(_ squareMeters: Double) -> String {
        guard squareMeters.isFinite else { return "—" }
        let value: Double
        let unit: String
        switch system {
        case .feetInches, .decimalFeet:
            value = squareMeters / UnitConstants.squareMetersPerSquareFoot
            unit = "sq ft"
        case .meters, .centimeters:
            value = squareMeters
            unit = "m²"
        }
        let whole = Int(value.rounded())
        var digits = String(abs(whole))
        var grouped = ""
        while digits.count > 3 {
            grouped = "," + digits.suffix(3) + grouped
            digits = String(digits.dropLast(3))
        }
        return "\(whole < 0 ? "-" : "")\(digits)\(grouped) \(unit)"
    }

    /// Linear-footage style value (trim, molding), e.g. `41.3 LF`.
    public func linearFeet(_ meters: Double) -> String {
        switch system {
        case .feetInches, .decimalFeet:
            return String(format: "%.1f LF", meters / UnitConstants.metersPerFoot)
        case .meters, .centimeters:
            return String(format: "%.2f m", meters)
        }
    }

    // MARK: Volume

    /// Formats a volume in cubic meters, e.g. `1,024 cu ft` (room air volume
    /// for HVAC sizing, demolition haul-off).
    public func volume(_ cubicMeters: Double) -> String {
        guard cubicMeters.isFinite else { return "—" }
        switch system {
        case .feetInches, .decimalFeet:
            let cubicFeet = cubicMeters / UnitConstants.cubicMetersPerCubicFoot
            return String(format: "%.0f cu ft", cubicFeet)
        case .meters, .centimeters:
            return String(format: "%.1f m³", cubicMeters)
        }
    }

    // MARK: Imperial core

    /// Renders meters as feet + fractional inches with carry handling.
    /// `denominator` is the fraction denominator (1, 2, 4, 8, 16).
    public static func feetInchesString(meters: Double, denominator: Int) -> String {
        let sign = meters < 0 ? "-" : ""
        let totalInches = abs(meters) / UnitConstants.metersPerInch
        let denom = max(1, denominator)

        // Round to the nearest 1/denom inch. The rounded tick count already
        // carries fractions into whole inches and inches into feet.
        let ticks = Int((totalInches * Double(denom)).rounded())
        let wholeInches = ticks / denom
        let numerator = max(0, ticks - wholeInches * denom)

        let feet = wholeInches / 12
        let inches = wholeInches % 12

        // Reduce fraction (e.g. 6/8 -> 3/4).
        var num = numerator
        var den = denom
        while num > 0, num % 2 == 0, den % 2 == 0 {
            num /= 2
            den /= 2
        }

        let inchPart: String
        if num > 0 {
            inchPart = inches > 0 ? "\(inches) \(num)/\(den)\"" : "\(num)/\(den)\""
        } else {
            inchPart = "\(inches)\""
        }

        if feet > 0 {
            return "\(sign)\(feet)' \(inchPart)"
        } else {
            return "\(sign)\(inchPart)"
        }
    }

    /// Convenience: total inches for a length in meters (unrounded).
    public static func totalInches(meters: Double) -> Double {
        meters / UnitConstants.metersPerInch
    }
}

/// Parses contractor-style length input into meters.
///
/// Accepted forms (whitespace tolerant):
///   12'            -> 12 feet
///   12' 6"         -> 12 ft 6 in
///   12'6"          -> 12 ft 6 in
///   12 6           -> 12 ft 6 in (bare two numbers = feet + inches)
///   12' 6 1/2"     -> 12 ft 6.5 in
///   6 3/8"         -> 6.375 in
///   84"            -> 84 in
///   7'             -> 7 ft
///   0' 11 7/8"     -> 11.875 in
///   3/4"           -> 0.75 in
///   12.5'          -> 12.5 ft
///   2.5m / 250cm / 320 mm -> metric
///   12             -> 12 feet (bare single number defaults to feet)
public enum DimensionParser {

    public enum ParseError: Error, Equatable {
        case empty
        case invalid(String)
    }

    /// Parses input and returns meters. Returns nil for invalid input.
    public static func parseLength(_ input: String) -> Double? {
        try? parseLengthThrowing(input)
    }

    public static func parseLengthThrowing(_ input: String) throws -> Double {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ParseError.empty }

        // Normalize typographic quotes and unicode fractions.
        var s = raw
            .replacingOccurrences(of: "\u{2019}", with: "'")  // ’
            .replacingOccurrences(of: "\u{2032}", with: "'")  // ′
            .replacingOccurrences(of: "\u{201D}", with: "\"") // ”
            .replacingOccurrences(of: "\u{2033}", with: "\"") // ″
            .replacingOccurrences(of: "\u{2044}", with: "/")  // fraction slash
            .lowercased()
        let unicodeFractions: [String: String] = [
            "\u{00BD}": " 1/2", "\u{00BC}": " 1/4", "\u{00BE}": " 3/4",
            "\u{215B}": " 1/8", "\u{215C}": " 3/8", "\u{215D}": " 5/8", "\u{215E}": " 7/8",
            "\u{2153}": " 1/3", "\u{2154}": " 2/3",
            "\u{2159}": " 1/6", "\u{215A}": " 5/6",
            "\u{2155}": " 1/5",
        ]
        for (glyph, replacement) in unicodeFractions {
            s = s.replacingOccurrences(of: glyph, with: replacement)
        }

        var negative = false
        if s.hasPrefix("-") {
            negative = true
            s.removeFirst()
            s = s.trimmingCharacters(in: .whitespaces)
        }

        // Metric forms.
        if let meters = parseMetric(s) {
            return negative ? -meters : meters
        }

        // Word units.
        s = s
            .replacingOccurrences(of: "feet", with: "'")
            .replacingOccurrences(of: "foot", with: "'")
            .replacingOccurrences(of: "ft.", with: "'")
            .replacingOccurrences(of: "ft", with: "'")
            .replacingOccurrences(of: "inches", with: "\"")
            .replacingOccurrences(of: "inch", with: "\"")
            .replacingOccurrences(of: "in.", with: "\"")
            // Do NOT blanket-replace "in" (would corrupt nothing here since
            // digits/fractions only, but keep it safe):
            .replacingOccurrences(of: " in", with: "\"")

        let meters = try parseImperial(s)
        guard meters.isFinite else { throw ParseError.invalid(raw) }
        return negative ? -meters : meters
    }

    // MARK: - Private

    private static func parseMetric(_ s: String) -> Double? {
        let compact = s.replacingOccurrences(of: " ", with: "")
        func number(dropping suffix: String) -> Double? {
            guard compact.hasSuffix(suffix) else { return nil }
            let body = String(compact.dropLast(suffix.count))
            guard !body.isEmpty else { return nil }
            return Double(body)
        }
        if let mm = number(dropping: "mm") { return mm / 1000 }
        if let cm = number(dropping: "cm") { return cm / 100 }
        if let m = number(dropping: "meters") { return m }
        if let m = number(dropping: "meter") { return m }
        if let m = number(dropping: "m"), !compact.contains("'"), !compact.contains("\"") {
            return m
        }
        return nil
    }

    /// Token-based imperial parser.
    private static func parseImperial(_ input: String) throws -> Double {
        // Tokenize into numbers, fractions, and unit markers.
        enum Token {
            case number(Double)
            case fraction(Double) // already evaluated numerator/denominator
            case feetMark
            case inchMark
        }

        var tokens: [Token] = []
        var index = input.startIndex

        func peek() -> Character? { index < input.endIndex ? input[index] : nil }
        func advance() { index = input.index(after: index) }

        while let c = peek() {
            if c == " " || c == "\t" || c == "-" && !tokens.isEmpty {
                // Treat interior dashes as separators: "12'-6\"" style.
                advance()
                continue
            }
            if c == "'" {
                tokens.append(.feetMark)
                advance()
                continue
            }
            if c == "\"" {
                tokens.append(.inchMark)
                advance()
                continue
            }
            if c.isNumber || c == "." {
                // Read a numeric run.
                var numStr = ""
                while let ch = peek(), ch.isNumber || ch == "." {
                    numStr.append(ch)
                    advance()
                }
                // Fraction directly attached: "3/8"
                if peek() == "/" {
                    advance()
                    var denStr = ""
                    while let ch = peek(), ch.isNumber {
                        denStr.append(ch)
                        advance()
                    }
                    guard let n = Double(numStr), let d = Double(denStr), d > 0 else {
                        throw ParseError.invalid(input)
                    }
                    tokens.append(.fraction(n / d))
                } else {
                    guard let n = Double(numStr) else { throw ParseError.invalid(input) }
                    tokens.append(.number(n))
                }
                continue
            }
            throw ParseError.invalid(input)
        }

        guard !tokens.isEmpty else { throw ParseError.empty }

        // Interpret token stream.
        var feet: Double? = nil
        var inches: Double = 0
        var sawInchesComponent = false

        // Pending numeric values not yet assigned to a unit.
        var pending: [Double] = []
        var pendingHasFraction = false

        func flushPendingAsInches() {
            guard !pending.isEmpty else { return }
            inches += pending.reduce(0, +)
            sawInchesComponent = true
            pending.removeAll()
            pendingHasFraction = false
        }

        for token in tokens {
            switch token {
            case .number(let n):
                pending.append(n)
            case .fraction(let f):
                pending.append(f)
                pendingHasFraction = true
            case .feetMark:
                // Everything pending becomes feet (e.g. "12'").
                guard !pending.isEmpty, feet == nil else {
                    throw ParseError.invalid(input)
                }
                feet = pending.reduce(0, +)
                pending.removeAll()
                pendingHasFraction = false
            case .inchMark:
                // Everything pending becomes inches (e.g. "6 1/2\"").
                if pending.isEmpty {
                    // A dangling inch mark after already-flushed values is
                    // harmless (e.g. quote repeated); otherwise invalid.
                    if !sawInchesComponent { throw ParseError.invalid(input) }
                } else {
                    flushPendingAsInches()
                }
            }
        }

        // Leftover values with no unit mark.
        if !pending.isEmpty {
            if feet != nil {
                // "12' 6" (no inch mark) -> pending is inches
                flushPendingAsInches()
            } else {
                if pending.count == 1 && !pendingHasFraction {
                    // Bare single number defaults to feet.
                    feet = pending[0]
                    pending.removeAll()
                } else if pending.count >= 2 && !pendingHasFraction {
                    // "12 6" -> feet + inches; "12 6 1/2" handled below
                    feet = pending[0]
                    inches += pending.dropFirst().reduce(0, +)
                    sawInchesComponent = true
                    pending.removeAll()
                } else if pendingHasFraction {
                    if pending.count >= 2, pending[0] >= 1,
                       pending[0].truncatingRemainder(dividingBy: 1) == 0,
                       pending.count >= 3 {
                        // "12 6 1/2" -> 12 ft, 6.5 in
                        feet = pending[0]
                        inches += pending.dropFirst().reduce(0, +)
                    } else {
                        // "6 3/8" or "3/8" -> inches
                        inches += pending.reduce(0, +)
                    }
                    sawInchesComponent = true
                    pending.removeAll()
                }
            }
        }

        let totalMeters = (feet ?? 0) * UnitConstants.metersPerFoot
            + inches * UnitConstants.metersPerInch
        if feet == nil && !sawInchesComponent {
            throw ParseError.invalid(input)
        }
        return totalMeters
    }
}
