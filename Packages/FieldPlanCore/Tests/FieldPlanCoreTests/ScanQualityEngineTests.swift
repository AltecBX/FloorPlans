import XCTest
@testable import FieldPlanCore

/// The live quality engine must speak up for real problems and stay quiet
/// during a normal walk — and never flicker.
final class ScanQualityEngineTests: XCTestCase {

    /// Feeds a straight walk at `speed` m/s for `seconds`, 10 Hz, returning
    /// the final state.
    private func walk(
        _ engine: inout ScanQualityEngine,
        speed: Double,
        seconds: Double,
        from start: Double = 0,
        turnRate: Double = 0,
        tracking: TrackingQuality = .normal,
        light: Double? = 900,
        depth: DepthConfidenceStats? = DepthConfidenceStats(high: 0.85, medium: 0.1, low: 0.05)
    ) -> ScanQualityState {
        var state = engine.state
        let steps = Int(seconds * 10)
        for i in 0...steps {
            let t = start + Double(i) / 10
            let x = speed * (t - start)
            let yaw = turnRate * (t - start)
            state = engine.ingest(PoseSample(
                time: t,
                transform: PoseSample.transform(position: Vec3(x, 1.4, 0), yaw: yaw),
                tracking: tracking,
                depthAvailable: depth != nil,
                depthConfidence: depth,
                ambientIntensity: light))
        }
        return state
    }

    func testNormalWalkGivesNoAdvice() {
        var engine = ScanQualityEngine()
        let state = walk(&engine, speed: 1.0, seconds: 4)
        XCTAssertTrue(state.advice.isEmpty, "\(state.advice.map(\.kind))")
        XCTAssertEqual(state.speed, 1.0, accuracy: 0.05)
        XCTAssertEqual(state.overall, .good)
        XCTAssertEqual(state.distanceWalked, 4, accuracy: 0.05)
    }

    func testRunningAsksToSlowDownAndClearsAfterSlowing() {
        var engine = ScanQualityEngine()
        var state = walk(&engine, speed: 2.2, seconds: 3)
        XCTAssertTrue(state.advice.contains { $0.kind == .slowDown }, "\(state.advice.map(\.kind))")
        XCTAssertEqual(state.overall, .caution)

        // Slowing right down: the advice lingers for the display minimum,
        // then goes.
        state = walk(&engine, speed: 0.5, seconds: 1, from: 3)
        XCTAssertTrue(state.advice.contains { $0.kind == .slowDown }, "should not vanish instantly")
        state = walk(&engine, speed: 0.5, seconds: 3, from: 4)
        XCTAssertFalse(state.advice.contains { $0.kind == .slowDown })
    }

    func testSpinningAsksToTurnSlowly() {
        var engine = ScanQualityEngine()
        let state = walk(&engine, speed: 0, seconds: 3, turnRate: 3.5) // ≈ 200°/s
        XCTAssertTrue(state.advice.contains { $0.kind == .turnSlowly }, "\(state.advice.map(\.kind))")
        XCTAssertGreaterThan(state.angularSpeed, 150)
    }

    func testGyroOverridesPoseRotationEstimate() {
        var engine = ScanQualityEngine()
        for i in 0...30 {
            let t = Double(i) / 10
            engine.ingest(motion: MotionSample(time: t, gravity: Vec3(0, -1, 0),
                                               rotationRate: Vec3(0, 4, 0), userAcceleration: .zero))
            engine.ingest(PoseSample(time: t, transform: PoseSample.transform(position: Vec3(0, 1.4, 0), yaw: 0)))
        }
        XCTAssertTrue(engine.state.advice.contains { $0.kind == .turnSlowly })
    }

    func testLimitedTrackingShowsAfterShortHold() {
        var engine = ScanQualityEngine()
        var state = walk(&engine, speed: 0.8, seconds: 0.2, tracking: .excessiveMotion)
        XCTAssertFalse(state.advice.contains { $0.kind == .excessiveMotion }, "0.2 s is below the hold")
        state = walk(&engine, speed: 0.8, seconds: 1, from: 0.3, tracking: .excessiveMotion)
        XCTAssertTrue(state.advice.contains { $0.kind == .excessiveMotion })
        XCTAssertEqual(state.overall, .poor)
    }

    func testTrackingLostIsImmediateAndFirst() {
        var engine = ScanQualityEngine()
        _ = walk(&engine, speed: 2.5, seconds: 2)
        let state = walk(&engine, speed: 2.5, seconds: 0.1, from: 2.1, tracking: .notAvailable)
        XCTAssertEqual(state.primaryAdvice?.kind, .trackingNotAvailable)
        XCTAssertTrue(state.advice.contains { $0.kind == .slowDown })
    }

    func testLowLightAndLowDepthConfidence() {
        var engine = ScanQualityEngine()
        let state = walk(&engine, speed: 0.8, seconds: 2, light: 120,
                         depth: DepthConfidenceStats(high: 0.2, medium: 0.3, low: 0.5))
        let kinds = Set(state.advice.map(\.kind))
        XCTAssertTrue(kinds.contains(.lowLight), "\(kinds)")
        XCTAssertTrue(kinds.contains(.lowDepthConfidence), "\(kinds)")
        // Light comes before depth in priority.
        XCTAssertEqual(state.primaryAdvice?.kind, .lowLight)
    }

    func testNoDepthSensorMeansNoDepthAdvice() {
        var engine = ScanQualityEngine()
        let state = walk(&engine, speed: 0.8, seconds: 2, depth: nil)
        XCTAssertFalse(state.advice.contains { $0.kind == .lowDepthConfidence })
    }

    func testExternalInstructionsPassThroughImmediately() {
        var engine = ScanQualityEngine()
        _ = walk(&engine, speed: 0.8, seconds: 1)
        engine.setExternal(.moveCloser, active: true, time: 1.0)
        XCTAssertEqual(engine.state.primaryAdvice?.kind, .moveCloser)
        engine.setExternal(.moveCloser, active: false, time: 1.1)
        XCTAssertTrue(engine.state.advice.isEmpty)
    }

    func testCoverageAdviceReplacesPreviousCoverageAdvice() {
        var engine = ScanQualityEngine()
        engine.setCoverageAdvice([.wallNotCovered, .cornerNotCovered], time: 1)
        XCTAssertEqual(Set(engine.state.advice.map(\.kind)), [.wallNotCovered, .cornerNotCovered])
        engine.setCoverageAdvice([.openingNotCovered], time: 2)
        XCTAssertEqual(Set(engine.state.advice.map(\.kind)), [.openingNotCovered])
        engine.setCoverageAdvice([], time: 3)
        XCTAssertTrue(engine.state.advice.isEmpty)
    }
}
