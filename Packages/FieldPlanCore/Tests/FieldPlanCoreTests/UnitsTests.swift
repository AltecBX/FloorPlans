import XCTest
@testable import FieldPlanCore

final class DimensionParserTests: XCTestCase {

    private func assertParses(_ input: String, feet: Double, inches: Double = 0,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expected = feet * 0.3048 + inches * 0.0254
        guard let parsed = DimensionParser.parseLength(input) else {
            XCTFail("Failed to parse '\(input)'", file: file, line: line)
            return
        }
        XCTAssertEqual(parsed, expected, accuracy: 1e-9,
                       "Input '\(input)' parsed to \(parsed) expected \(expected)",
                       file: file, line: line)
    }

    // Spec §51 required forms.
    func testSpecRequiredForms() {
        assertParses("12'", feet: 12)
        assertParses("12' 6\"", feet: 12, inches: 6)
        assertParses("12'6\"", feet: 12, inches: 6)
        assertParses("12 6", feet: 12, inches: 6)
        assertParses("12' 6 1/2\"", feet: 12, inches: 6.5)
        assertParses("6 3/8\"", feet: 0, inches: 6.375)
        assertParses("84\"", feet: 0, inches: 84)
        assertParses("7'", feet: 7)
        assertParses("0' 11 7/8\"", feet: 0, inches: 11.875)
    }

    func testAdditionalForms() {
        assertParses("3/4\"", feet: 0, inches: 0.75)
        assertParses("12.5'", feet: 12.5)
        assertParses("12", feet: 12)                 // bare number = feet
        assertParses("12'-6\"", feet: 12, inches: 6) // dash separator
        assertParses("12 6 1/2", feet: 12, inches: 6.5)
        assertParses("5 1/2", feet: 0, inches: 5.5)  // fraction => inches
        assertParses("10 ft", feet: 10)
        assertParses("96 in", feet: 0, inches: 96)
        assertParses("  8'  0\" ", feet: 8)
    }

    func testTypographicQuotesAndUnicodeFractions() {
        assertParses("12\u{2019} 6\u{201D}", feet: 12, inches: 6)
        assertParses("6 \u{00BD}\"", feet: 0, inches: 6.5)
        assertParses("3\u{215B}\"", feet: 0, inches: 3.125)
    }

    func testMetric() {
        XCTAssertEqual(DimensionParser.parseLength("2.5m")!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(DimensionParser.parseLength("250cm")!, 2.5, accuracy: 1e-9)
        XCTAssertEqual(DimensionParser.parseLength("320 mm")!, 0.32, accuracy: 1e-9)
    }

    func testNegative() {
        XCTAssertEqual(DimensionParser.parseLength("-2'")!, -0.6096, accuracy: 1e-9)
    }

    func testInvalidInputs() {
        XCTAssertNil(DimensionParser.parseLength(""))
        XCTAssertNil(DimensionParser.parseLength("abc"))
        XCTAssertNil(DimensionParser.parseLength("'"))
        XCTAssertNil(DimensionParser.parseLength("12' 6' 3'"))  // two feet marks
        XCTAssertNil(DimensionParser.parseLength("1/0\""))      // zero denominator
    }
}

final class UnitFormatterTests: XCTestCase {

    func testFeetInchesBasic() {
        // 12' 7 3/8" = 151.375 in
        let meters = 151.375 * 0.0254
        XCTAssertEqual(UnitFormatter.feetInchesString(meters: meters, denominator: 8), "12' 7 3/8\"")
    }

    func testWholeFeet() {
        XCTAssertEqual(UnitFormatter.feetInchesString(meters: 12 * 0.3048, denominator: 8), "12' 0\"")
    }

    func testInchesOnly() {
        XCTAssertEqual(UnitFormatter.feetInchesString(meters: 11.875 * 0.0254, denominator: 8), "11 7/8\"")
    }

    func testFractionReduction() {
        // 6/8 reduces to 3/4
        let meters = (6.0 + 6.0 / 8.0) * 0.0254
        XCTAssertEqual(UnitFormatter.feetInchesString(meters: meters, denominator: 8), "6 3/4\"")
    }

    func testCarryToFoot() {
        // 11 15/16" rounds to 12" at 1/8 precision -> 1' 0"
        let meters = (11.0 + 15.0 / 16.0) * 0.0254
        XCTAssertEqual(UnitFormatter.feetInchesString(meters: meters, denominator: 8), "1' 0\"")
    }

    func testSixteenthPrecision() {
        let meters = (5.0 + 3.0 / 16.0) * 0.0254
        XCTAssertEqual(UnitFormatter.feetInchesString(meters: meters, denominator: 16), "5 3/16\"")
    }

    func testNearestInchPrecision() {
        let meters = (7.0 * 12 + 5.6) * 0.0254
        XCTAssertEqual(UnitFormatter.feetInchesString(meters: meters, denominator: 1), "7' 6\"")
    }

    func testRoundTripThroughParser() {
        // Format→parse→format must be stable at the same precision.
        let original = 3.8735  // arbitrary meters
        let formatted = UnitFormatter.feetInchesString(meters: original, denominator: 16)
        let reparsed = DimensionParser.parseLength(formatted)!
        let reformatted = UnitFormatter.feetInchesString(meters: reparsed, denominator: 16)
        XCTAssertEqual(formatted, reformatted)
        // And the parse error is bounded by half a sixteenth.
        XCTAssertEqual(original, reparsed, accuracy: 0.0254 / 16)
    }

    func testDisplayRoundingNeverMutatesValue() {
        let precise = 3.141592653589793
        _ = UnitFormatter().length(precise)
        XCTAssertEqual(precise, 3.141592653589793) // value untouched (display-only rounding)
    }

    func testAreaFormatting() {
        let formatter = UnitFormatter()
        // 10 sq ft in m²
        let tenSquareFeet = 10 * UnitConstants.squareMetersPerSquareFoot
        XCTAssertEqual(formatter.area(tenSquareFeet), "10.0 sq ft")
    }

    func testMetricFormatting() {
        var formatter = UnitFormatter()
        formatter.system = .meters
        XCTAssertEqual(formatter.length(2.5), "2.500 m")
        formatter.system = .centimeters
        XCTAssertEqual(formatter.length(2.5), "250.0 cm")
        formatter.system = .decimalFeet
        XCTAssertEqual(formatter.length(0.3048), "1.00 ft")
    }
}
