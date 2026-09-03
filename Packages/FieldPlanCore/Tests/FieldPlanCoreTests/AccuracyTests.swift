import XCTest
@testable import FieldPlanCore

/// Accuracy numbers come from samples against a tape, nowhere else. These
/// check the arithmetic behind every figure the accuracy screen can show.
final class AccuracyTests: XCTestCase {

    let inch = UnitConstants.metersPerInch

    private func sample(_ kind: AccuracyMeasureKind, _ name: String, known: Double, measured: Double,
                        confidence: Double? = nil, alternate: Double? = nil) -> AccuracySample {
        AccuracySample(kind: kind, name: name, knownValue: known, measuredValue: measured,
                       alternateValue: alternate, predictedConfidence: confidence)
    }

    func testStatisticsOverKnownErrors() {
        // Errors in inches: +1, -1, +2, -2, +0.5
        let base = 120 * inch
        let samples = [
            sample(.wallLength, "a", known: base, measured: base + 1 * inch),
            sample(.wallLength, "b", known: base, measured: base - 1 * inch),
            sample(.wallLength, "c", known: base, measured: base + 2 * inch),
            sample(.wallLength, "d", known: base, measured: base - 2 * inch),
            sample(.wallLength, "e", known: base, measured: base + 0.5 * inch),
        ]
        let stats = AccuracyStatistics.compute(samples)!
        XCTAssertEqual(stats.count, 5)
        XCTAssertEqual(stats.meanAbsoluteError / inch, 1.3, accuracy: 1e-9)
        XCTAssertEqual(stats.medianAbsoluteError / inch, 1.0, accuracy: 1e-9)
        XCTAssertEqual(stats.maxAbsoluteError / inch, 2.0, accuracy: 1e-9)
        // Sorted |e| = 0.5, 1, 1, 2, 2; p95 sits at index 3.8 → 2.0.
        XCTAssertEqual(stats.p95AbsoluteError / inch, 2.0, accuracy: 1e-9)
        XCTAssertEqual(stats.meanSignedError / inch, 0.1, accuracy: 1e-9)
        XCTAssertEqual(stats.withinOneInch ?? 0, 3.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(stats.withinHalfInch ?? 0, 1.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(stats.withinThreePercent ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(stats.meanPercentError ?? 0, 1.3 / 120 * 100, accuracy: 1e-9)
    }

    func testPercentileInterpolates() {
        XCTAssertEqual(AccuracyStatistics.percentile([1, 2, 3, 4], 0.5), 2.5, accuracy: 1e-9)
        XCTAssertEqual(AccuracyStatistics.percentile([1, 2, 3, 4], 0), 1, accuracy: 1e-9)
        XCTAssertEqual(AccuracyStatistics.percentile([1, 2, 3, 4], 1), 4, accuracy: 1e-9)
        XCTAssertEqual(AccuracyStatistics.percentile([7], 0.95), 7, accuracy: 1e-9)
        XCTAssertEqual(AccuracyStatistics.percentile([], 0.5), 0, accuracy: 1e-9)
    }

    func testEmptyGivesNothing() {
        XCTAssertNil(AccuracyStatistics.compute([]))
        XCTAssertTrue(AccuracyStatistics.byKind([]).isEmpty)
    }

    func testByKindSeparatesAreasFromLengths() {
        let samples = [
            sample(.wallLength, "a", known: 3, measured: 3.01),
            sample(.roomArea, "r", known: 20, measured: 20.5),
        ]
        let byKind = AccuracyStatistics.byKind(samples)
        XCTAssertEqual(byKind.count, 2)
        XCTAssertNil(byKind[.roomArea]?.withinOneInch, "inch figures mean nothing for areas")
        XCTAssertNotNil(byKind[.wallLength]?.withinOneInch)
        XCTAssertEqual(byKind[.roomArea]?.meanPercentError ?? 0, 2.5, accuracy: 1e-9)
    }

    func testRepeatabilityAcrossScans() {
        let samples = [
            sample(.wallLength, "Kitchen north", known: 4.0, measured: 4.00),
            sample(.wallLength, "Kitchen north", known: 4.0, measured: 4.02),
            sample(.wallLength, "kitchen north", known: 4.0, measured: 3.98),
            sample(.doorWidth, "Front door", known: 0.9, measured: 0.91),
        ]
        let groups = AccuracyAnalysis.repeatability(samples)
        XCTAssertEqual(groups.count, 1, "single samples are not repeats")
        let g = groups[0]
        XCTAssertEqual(g.count, 3)
        XCTAssertEqual(g.mean, 4.0, accuracy: 1e-9)
        XCTAssertEqual(g.standardDeviation, 0.02, accuracy: 1e-9)
        XCTAssertEqual(g.range, 0.04, accuracy: 1e-9)
    }

    func testCalibrationBinsReportObservedError() {
        let samples = [
            sample(.wallLength, "a", known: 3, measured: 3 + 0.5 * inch, confidence: 0.95),
            sample(.wallLength, "b", known: 3, measured: 3 + 0.8 * inch, confidence: 0.90),
            sample(.wallLength, "c", known: 3, measured: 3 + 3.0 * inch, confidence: 0.40),
            sample(.wallLength, "d", known: 3, measured: 3 + 1.5 * inch, confidence: 0.70),
            sample(.wallLength, "e", known: 3, measured: 3 + 1.0 * inch),   // no prediction
        ]
        let bins = AccuracyAnalysis.calibration(samples)
        XCTAssertEqual(bins.count, 3)
        let high = bins.first { $0.lower == ConfidenceModel.highBand }!
        XCTAssertEqual(high.count, 2)
        XCTAssertEqual(high.withinOneInch ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(high.meanAbsoluteError / inch, 0.65, accuracy: 1e-9)
        let low = bins.first { $0.lower == 0 }!
        XCTAssertEqual(low.count, 1)
        XCTAssertEqual(low.withinOneInch ?? 1, 0, accuracy: 1e-9)
    }

    func testAlternateComparison() {
        let samples = [
            sample(.wallLength, "a", known: 3, measured: 3.03, alternate: 3.01),
            sample(.wallLength, "b", known: 4, measured: 4.02, alternate: 4.04),
            sample(.wallLength, "c", known: 5, measured: 5.01),   // no alternate → excluded
        ]
        let comparison = AccuracyAnalysis.alternateComparison(samples)!
        XCTAssertEqual(comparison.primary.count, 2)
        XCTAssertEqual(comparison.primary.meanAbsoluteError, 0.025, accuracy: 1e-9)
        XCTAssertEqual(comparison.alternate.meanAbsoluteError, 0.025, accuracy: 1e-9)
        XCTAssertNil(AccuracyAnalysis.alternateComparison([samples[2]]))
    }

    func testSampleRoundTripsThroughJSON() throws {
        let s = sample(.doorWidth, "Front door", known: 0.9144, measured: 0.92, confidence: 0.88)
        let data = try ProjectArchive.encoder().encode(s)
        let decoded = try ProjectArchive.decoder().decode(AccuracySample.self, from: data)
        XCTAssertEqual(decoded.kind, .doorWidth)
        XCTAssertEqual(decoded.error, s.error, accuracy: 1e-12)
        XCTAssertEqual(decoded.predictedConfidence, 0.88)
    }
}

/// The evidence score is a documented heuristic; these pin its behaviour so
/// a calibration change is deliberate.
final class ConfidenceModelTests: XCTestCase {

    func testScannerBucketOrdersTheBase() {
        let high = ConfidenceModel.evidence(scanner: .high).confidence
        let medium = ConfidenceModel.evidence(scanner: .medium).confidence
        let low = ConfidenceModel.evidence(scanner: .low).confidence
        XCTAssertGreaterThan(high, medium)
        XCTAssertGreaterThan(medium, low)
        XCTAssertEqual(ConfidenceModel.evidence(scanner: nil).confidence, 0.70, accuracy: 1e-9)
    }

    func testCoverageAndTrackingScaleTheScore() {
        let full = ConfidenceModel.evidence(scanner: .high, coverage: 1.0, trackingQuality: 1.0)
        let half = ConfidenceModel.evidence(scanner: .high, coverage: 0.5, trackingQuality: 1.0)
        let shaky = ConfidenceModel.evidence(scanner: .high, coverage: 1.0, trackingQuality: 0.4)
        XCTAssertGreaterThan(full.confidence, half.confidence)
        XCTAssertGreaterThan(full.confidence, shaky.confidence)
        XCTAssertEqual(full.factors.count, 3)
        XCTAssertEqual(full.factors.map(\.name), ["scanner", "coverage", "tracking"])
    }

    func testScoresStayInsideTheClamp() {
        let best = ConfidenceModel.evidence(scanner: .high, coverage: 1, observationCount: 500,
                                            trackingQuality: 1, bothSidesSeen: true,
                                            alternate: AlternateMeasurement(method: "mesh", value: 1, residual: 0.005))
        XCTAssertLessThanOrEqual(best.confidence, ConfidenceModel.maximum)
        XCTAssertGreaterThan(best.confidence, 0.9)
        let worst = ConfidenceModel.evidence(scanner: .low, coverage: 0, observationCount: 1, trackingQuality: 0)
        XCTAssertGreaterThanOrEqual(worst.confidence, ConfidenceModel.minimum)
        XCTAssertLessThan(worst.confidence, 0.3)
        XCTAssertEqual(worst.band, .low)
        XCTAssertEqual(best.band, .high)
    }

    func testPercentTextNeverClaimsCertainty() {
        XCTAssertEqual(ConfidenceModel.percent(1.0), 99)
        XCTAssertEqual(ConfidenceModel.percent(0.0), 5)
        XCTAssertEqual(ElementEvidence(confidence: 0.923).percentText, "92%")
    }

    func testRoomIsLimitedByItsWeakestWall() {
        let strong = ElementEvidence(confidence: 0.95)
        let weak = ElementEvidence(confidence: 0.30)
        let room = ConfidenceModel.roomEvidence(wallEvidence: [strong, strong, strong, weak],
                                                floorCoverage: 1.0, isClosed: true)
        XCTAssertLessThan(room.confidence, 0.65)
        let open = ConfidenceModel.roomEvidence(wallEvidence: [strong, strong], floorCoverage: 1.0, isClosed: false)
        let closed = ConfidenceModel.roomEvidence(wallEvidence: [strong, strong], floorCoverage: 1.0, isClosed: true)
        XCTAssertLessThan(open.confidence, closed.confidence)
    }

    func testAttachmentLeavesHandEnteredGeometryAlone() {
        let level = SampleFixtures.apartment()   // every wall is sample data
        let scored = EvidenceAttachment.attach(to: level, grid: nil, trackingNormalFraction: 1, sessionID: nil)
        XCTAssertTrue(scored.walls.allSatisfy { $0.evidence == nil })
        XCTAssertTrue(scored.rooms.allSatisfy { $0.evidence != nil }, "rooms still get a closure/wall summary")
    }

    func testLegacySnapshotWithoutEvidenceStillDecodes() throws {
        // A version-1 file has none of the new optional keys.
        let json = """
        {"id":"\(UUID().uuidString)","name":"Existing","kind":"existingConditions","isLocked":false,
         "createdAt":"2026-08-30T00:00:00Z","levels":[{"id":"\(UUID().uuidString)","name":"L1","storyIndex":0,
         "walls":[{"id":"\(UUID().uuidString)","start":{"x":0,"y":0},"end":{"x":3,"y":0},"height":2.4,
         "thickness":0.11,"openings":[{"id":"\(UUID().uuidString)","kind":"door","centerOffset":1,"width":0.9,
         "height":2,"sillHeight":0,"changeStatus":"existing","source":"lidarScanned","confidence":"high"}],
         "changeStatus":"existing","source":"lidarScanned","confidence":"high"}],
         "rooms":[],"fixtures":[],"annotations":[]}]}
        """
        let snapshot = try ProjectArchive.decoder().decode(PlanSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snapshot.schemaVersion)
        XCTAssertNil(snapshot.levels[0].walls[0].evidence)
        XCTAssertNil(snapshot.levels[0].walls[0].thicknessSource)
        XCTAssertEqual(snapshot.levels[0].walls[0].openings[0].resolvedStyle, .hinged)
    }
}
