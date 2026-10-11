import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// FORK-ONLY, not ported to Android. Pure-function tests for SubstrateEstimator — the approximate
/// fat-vs-carbohydrate energy-split-during-exercise estimate behind the workout substrate %. No prior
/// art elsewhere in this repo; this model is new, so these tests pin its actual behavior rather than
/// cross-checking against an existing oracle.
final class SubstrateEstimatorTests: XCTestCase {

    private let resting = 60.0
    private let max = 180.0   // hrReserve = 120

    private func hr(_ pairs: [(tsOffset: Int, bpm: Int)]) -> [HRSample] {
        pairs.map { HRSample(ts: $0.tsOffset, bpm: $0.bpm) }
    }

    // MARK: - Direction / control points

    func testFatDominatesAtLowIntensity() {
        // 84 bpm -> %HRR = (84-60)/120*100 = 20%, inside the flat (0,70)-(40,70) plateau.
        let e = SubstrateEstimator.estimate(hr: hr([(0, 84), (60, 84)]), restingHR: resting, maxHR: max,
                                            totalKcal: 100)!
        XCTAssertEqual(e.fatPct, 70, accuracy: 1e-6)
        XCTAssertEqual(e.carbPct, 30, accuracy: 1e-6)
    }

    func testCarbDominatesAtHighIntensity() {
        // 174 bpm -> %HRR = (174-60)/120*100 = 95%, inside the near-maximal (85,15)-(100,5) segment.
        let e = SubstrateEstimator.estimate(hr: hr([(0, 174), (60, 174)]), restingHR: resting, maxHR: max,
                                            totalKcal: 100)!
        XCTAssertGreaterThan(e.carbPct, 85)
        XCTAssertLessThan(e.fatPct, 15)
    }

    func testInterpolatesBetweenControlPoints() {
        // 140 bpm -> %HRR = 66.67%, between (55,55) and (70,35): frac=(66.67-55)/15=0.778,
        // fatPct = 55 - 0.778*20 = 39.44%.
        let e = SubstrateEstimator.estimate(hr: hr([(0, 140), (60, 140)]), restingHR: resting, maxHR: max,
                                            totalKcal: 500)!
        XCTAssertEqual(e.meanHRRPct, 66.666667, accuracy: 1e-4)
        XCTAssertEqual(e.fatPct, 39.444444, accuracy: 1e-3)
        XCTAssertEqual(e.carbPct, 60.555556, accuracy: 1e-3)
    }

    func testControlPointFatPercentDirect() {
        XCTAssertEqual(SubstrateEstimator.fatPercent(forMeanHRRPercent: 0), 70, accuracy: 1e-9)
        XCTAssertEqual(SubstrateEstimator.fatPercent(forMeanHRRPercent: 40), 70, accuracy: 1e-9)
        XCTAssertEqual(SubstrateEstimator.fatPercent(forMeanHRRPercent: 55), 55, accuracy: 1e-9)
        XCTAssertEqual(SubstrateEstimator.fatPercent(forMeanHRRPercent: 100), 5, accuracy: 1e-9)
        // Out-of-range inputs clamp to the end control points rather than extrapolating.
        XCTAssertEqual(SubstrateEstimator.fatPercent(forMeanHRRPercent: -10), 70, accuracy: 1e-9)
        XCTAssertEqual(SubstrateEstimator.fatPercent(forMeanHRRPercent: 150), 5, accuracy: 1e-9)
    }

    // MARK: - Honesty gates: nil, never a fabricated split

    func testNilOnEmptyHR() {
        XCTAssertNil(SubstrateEstimator.estimate(hr: [], restingHR: resting, maxHR: max, totalKcal: 100))
    }

    func testNilOnDegenerateMaxNotAboveResting() {
        XCTAssertNil(SubstrateEstimator.estimate(hr: hr([(0, 100)]), restingHR: 100, maxHR: 100, totalKcal: 100))
        XCTAssertNil(SubstrateEstimator.estimate(hr: hr([(0, 100)]), restingHR: 120, maxHR: 100, totalKcal: 100))
    }

    func testNilOnNonPositiveTotalKcal() {
        XCTAssertNil(SubstrateEstimator.estimate(hr: hr([(0, 140)]), restingHR: resting, maxHR: max, totalKcal: 0))
        XCTAssertNil(SubstrateEstimator.estimate(hr: hr([(0, 140)]), restingHR: resting, maxHR: max, totalKcal: -50))
    }

    // MARK: - kcal split

    func testKcalSplitSumsToTotal() {
        let e = SubstrateEstimator.estimate(hr: hr([(0, 140), (60, 150), (120, 130)]), restingHR: resting,
                                            maxHR: max, totalKcal: 613.0)!
        XCTAssertEqual(e.fatKcal + e.carbKcal, 613.0, accuracy: 1e-6)
    }

    // MARK: - Duration weighting (mirrors Calories.estimateBoutCalories's elapsed-time shape)

    func testDurationWeightedMeanHRRNotPlainSampleAverage() {
        // A 150s-long reading at max HR (capped at WorkoutDetector.mergeGapS) followed by one isolated
        // resting-HR reading must NOT average as a naive 50/50 sample count would (that would read
        // meanHRRPct ~50%); the long high-intensity span dominates the duration-weighted mean instead.
        let samples = hr([(0, 180), (200, 60)])   // gap capped at mergeGapS=150s; last sample carries 1s
        let e = SubstrateEstimator.estimate(hr: samples, restingHR: resting, maxHR: max, totalKcal: 100)!
        XCTAssertEqual(e.meanHRRPct, 99.337748, accuracy: 1e-3,
                       "weight=150 at 100% HRR + weight=1 at 0% HRR, over weight 151")
        XCTAssertGreaterThan(e.meanHRRPct, 90, "must be dominated by the long high-intensity span, not a 50/50 sample average")
    }

    func testInputOrderDoesNotChangeTheMean() {
        let forward = hr([(0, 180), (60, 60), (120, 140)])
        let reversed = Array(forward.reversed())
        let a = SubstrateEstimator.estimate(hr: forward, restingHR: resting, maxHR: max, totalKcal: 400)!
        let b = SubstrateEstimator.estimate(hr: reversed, restingHR: resting, maxHR: max, totalKcal: 400)!
        XCTAssertEqual(a.meanHRRPct, b.meanHRRPct, accuracy: 1e-9)
    }
}
