import XCTest
@testable import StrandAnalytics

/// FORK-ONLY, not ported to Android. Mirrors `SubstrateEstimatorTests`' shape for the gating logic,
/// plus the weight/duration scaling and rounding this estimator adds.
final class WorkoutCarbRefuelTests: XCTestCase {

    private func substrate(carbKcal: Double) -> SubstrateEstimator.SubstrateEstimate {
        SubstrateEstimator.SubstrateEstimate(meanHRRPct: 60, fatPct: 40, carbPct: 60,
                                             fatKcal: carbKcal, carbKcal: carbKcal)
    }

    func testBelowBothThresholdsReturnsNil() {
        // 20 min, 50 kcal carbs — neither gate clears.
        let out = WorkoutCarbRefuelEstimator.estimate(substrate: substrate(carbKcal: 50),
                                                       weightKg: 75, durationS: 20 * 60)
        XCTAssertNil(out)
    }

    func testDurationThresholdAloneQualifies() {
        // 50 min clears the duration gate even with a low carb-burn estimate.
        let out = WorkoutCarbRefuelEstimator.estimate(substrate: substrate(carbKcal: 10),
                                                       weightKg: 75, durationS: 50 * 60)
        XCTAssertNotNil(out)
    }

    func testCarbKcalThresholdAloneQualifies() {
        // A short but intense 10-minute bout that still burned 200 kcal of carbs clears the kcal gate.
        let out = WorkoutCarbRefuelEstimator.estimate(substrate: substrate(carbKcal: 200),
                                                       weightKg: 75, durationS: 10 * 60)
        XCTAssertNotNil(out)
    }

    func testNonPositiveWeightReturnsNil() {
        let out = WorkoutCarbRefuelEstimator.estimate(substrate: substrate(carbKcal: 300),
                                                       weightKg: 0, durationS: 60 * 60)
        XCTAssertNil(out)
    }

    func testScalesWithWeightAndDuration() {
        let out = WorkoutCarbRefuelEstimator.estimate(substrate: substrate(carbKcal: 400),
                                                       weightKg: 80, durationS: 2 * 3600)!
        XCTAssertEqual(out.windowHours, 2.0, accuracy: 1e-9)
        XCTAssertEqual(out.refuelTargetG, 160.0, accuracy: 1e-9)   // 80 * 1.0 g/kg/h * 2h
        XCTAssertEqual(out.carbsBurnedG, 100.0, accuracy: 1e-9)    // 400 kcal / 4
    }

    func testCapsAtFourHours() {
        let out = WorkoutCarbRefuelEstimator.estimate(substrate: substrate(carbKcal: 500),
                                                       weightKg: 70, durationS: 6 * 3600)!
        XCTAssertEqual(out.windowHours, 4.0, accuracy: 1e-9)       // capped, not 6
        XCTAssertEqual(out.refuelTargetG, 280.0, accuracy: 1e-9)   // 70 * 1.0 * 4h
    }

    func testRoundsToNearestFiveHalfRoundsUp() {
        // 72.5 kg * 1.0 g/kg/h * 1h = 72.5 -> nearest 5 rounds away from zero -> 75.
        let out = WorkoutCarbRefuelEstimator.estimate(substrate: substrate(carbKcal: 300),
                                                       weightKg: 72.5, durationS: 3600)!
        XCTAssertEqual(out.refuelTargetG, 75.0, accuracy: 1e-9)
    }
}
