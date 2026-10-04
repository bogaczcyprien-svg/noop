import XCTest
@testable import StrandAnalytics

/// The Charge driver list + relative skin-temp marker (SHARED CONTRACT). Proves the drivers come from
/// the SAME weighting `recovery(...)` uses, that a missing term yields NO row (never a fake one), that
/// the sign of each driver matches its real direction, and that the skin-temp relative tier banding is
/// honest. Twin of the Android RecoveryScorerChargeDriversTest. No em-dashes.
final class ChargeDriversTests: XCTestCase {

    /// A usable (trusted) baseline with a given mean and σ (Gaussian).
    private func baseline(mean: Double, sigma: Double, nValid: Int = 14) -> BaselineState {
        BaselineState(baseline: mean, spread: sigma / 1.253, nValid: nValid,
                      nightsSinceUpdate: 0, status: nValid >= 14 ? .trusted : .provisional)
    }

    // MARK: - Integer marginal rounding parity (#51)

    private func hrvMarginal(hrv: Double, rhr: Double, hrvBaseline: BaselineState,
                             rhrBaseline: BaselineState? = nil) -> (raw: Double, points: Int) {
        let full = RecoveryScorer.recovery(
            hrv: hrv, rhr: rhr, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
            respBaseline: nil, sleepPerf: nil)!
        let neutral = RecoveryScorer.recovery(
            hrv: hrvBaseline.baseline, rhr: rhr, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
            respBaseline: nil, sleepPerf: nil)!
        let row = RecoveryScorer.chargeDrivers(
            hrv: hrv, rhr: rhr, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: rhrBaseline,
            respBaseline: nil, sleepPerf: nil)
            .first { $0.label == "Heart rate variability" }!
        return (full - neutral, row.deltaPoints)
    }

    /// Bisect `hrv` over `[lo, hi]` for the boundary at which `hrvMarginal(...).raw` crosses
    /// `target`, narrowing until `lo`/`hi` are adjacent doubles. Self-calibrating against whatever
    /// RecoveryScorer tuning is compiled in (fork follow-up to #51): the ORIGINAL version of this
    /// test hardcoded magic `hrv` literals hand-derived to hit an exact ±0.5 tie under the upstream
    /// logisticK=1.6 — literals that silently stopped meaning "exact tie" the moment this fork
    /// retuned logisticK to 2.0, which is what actually broke this test. Bisecting at test time
    /// means it keeps testing the real boundary under whatever formula is actually running.
    ///
    /// Invariant held throughout (and so on return): `rawAt(lo)` is strictly on the
    /// not-yet-reached-target side, `rawAt(hi)` is on the at-or-past-target side. `raw` must be
    /// monotonic in hrv over `[lo, hi]` for this to converge to a real crossing, which holds for a
    /// single marginal HRV term — but NOT when a second, saturating term (e.g. an extreme RHR
    /// baseline) is also active, since the achievable raw range can then be capped below the target
    /// entirely (confirmed: that is what the original two-term positive fixture hit here, not a
    /// bisection bug — see the comment at its call site below).
    ///
    /// Deliberately does NOT try to also manufacture an exact floating-point tie (`raw == target`)
    /// partway between `lo` and `hi`: for a continuous real-valued function, landing exactly on a
    /// target double by bisection is not reliable, and a near-miss on either side silently changes
    /// which way the DISCRETE rounding falls — which is exactly the flaky failure this design hit
    /// before this rewrite. The tie-BREAKING rule itself (0.5 rounds away from zero) is already
    /// pinned directly on synthetic doubles in `RecoveryScorerTraceTests.testTraceRound2MatchesTheSwiftContract`
    /// and `.testTraceRoundsHalfTiesAwayFromZeroWithoutChangingScore`; this test's job is only to
    /// confirm the full pipeline correctly crosses the rounding boundary.
    private func bisectBoundary(target: Double, lo: Double, hi: Double,
                                rawAt: (Double) -> Double) -> (lo: Double, hi: Double) {
        var lo = lo, hi = hi
        let increasing = rawAt(hi) > rawAt(lo)
        for _ in 0..<100 {
            let mid = lo + (hi - lo) / 2
            if mid == lo || mid == hi { break }   // adjacent doubles: precision exhausted
            let r = rawAt(mid)
            if increasing ? (r < target) : (r > target) { lo = mid } else { hi = mid }
        }
        return (lo, hi)
    }

    func testDriverPointRoundingUsesNearestWithHalfTiesAwayFromZero() {
        let negativeBaseline = BaselineState(
            baseline: 30.0, spread: 0.55, nValid: 14,
            nightsSinceUpdate: 0, status: .trusted)
        // raw DECREASES as hrv drops further below baseline, so `lo` (lower hrv) is the side that
        // has crossed past -0.5 (points=-1) and `hi` is the side that has not yet (points=0).
        let (negativeBeyondHRV, negativeBelowHRV) = bisectBoundary(target: -0.5, lo: 29.0, hi: 30.0) {
            hrvMarginal(hrv: $0, rhr: 60.0, hrvBaseline: negativeBaseline).raw
        }
        let negativeBelowTie = hrvMarginal(hrv: negativeBelowHRV, rhr: 60.0, hrvBaseline: negativeBaseline)
        let negativeBeyondTie = hrvMarginal(hrv: negativeBeyondHRV, rhr: 60.0, hrvBaseline: negativeBaseline)
        XCTAssertGreaterThan(negativeBelowTie.raw, -0.5)
        XCTAssertEqual(negativeBelowTie.points, 0)
        XCTAssertLessThan(negativeBeyondTie.raw, -0.5)
        XCTAssertEqual(negativeBeyondTie.points, -1)

        // Fork note: the original fixture also pinned an extreme RHR baseline (spread=0.1) here,
        // making this the "two active terms" sibling of the single-term negative case above. Under
        // this fork's logisticK=2.0 that extreme RHR z alone already saturates the composite near
        // its ceiling (~99.87/100) before HRV gets a say, capping the achievable raw swing at
        // ~0.13 — mathematically unable to ever reach a 0.5 tie, which is what actually broke this
        // half (confirmed: compositeZ is a provably monotonic, affine function of hrv here, so the
        // earlier failure was never a bisection bug, just an unreachable target). Dropped the RHR
        // term — mirrors the negative case's single-term shape, which has headroom to spare.
        let positiveHRVBaseline = BaselineState(
            baseline: 30.0, spread: 0.55, nValid: 14,
            nightsSinceUpdate: 0, status: .trusted)
        // raw INCREASES as hrv rises further above baseline, so `lo` has not yet crossed +0.5
        // (points=0) and `hi` has (points=1).
        let (positiveBelowHRV, positiveBeyondHRV) = bisectBoundary(target: 0.5, lo: 30.0, hi: 36.0) {
            hrvMarginal(hrv: $0, rhr: 58.541, hrvBaseline: positiveHRVBaseline).raw
        }
        let positiveBelowTie = hrvMarginal(hrv: positiveBelowHRV, rhr: 58.541, hrvBaseline: positiveHRVBaseline)
        let positiveBeyondTie = hrvMarginal(hrv: positiveBeyondHRV, rhr: 58.541, hrvBaseline: positiveHRVBaseline)
        XCTAssertLessThan(positiveBelowTie.raw, 0.5)
        XCTAssertEqual(positiveBelowTie.points, 0)
        XCTAssertGreaterThan(positiveBeyondTie.raw, 0.5)
        XCTAssertEqual(positiveBeyondTie.points, 1)
    }

    func testIssue51NegativeHalfTieUsesDefaultArg8WithoutChangingScoreOrDriverFields() {
        let hrvBaseline = BaselineState(
            baseline: 30.0, spread: 0.55, nValid: 14,
            nightsSinceUpdate: 0, status: .trusted)
        // The crossed-boundary side (see bisectBoundary's doc comment): guaranteed raw < -0.5, so
        // guaranteed to round to -1, without relying on hitting an exact floating-point tie.
        let (beyondHRV, _) = bisectBoundary(target: -0.5, lo: 29.0, hi: 30.0) {
            hrvMarginal(hrv: $0, rhr: 60.0, hrvBaseline: hrvBaseline).raw
        }
        let scoreBefore = RecoveryScorer.recovery(
            hrv: beyondHRV, rhr: 60.0, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: nil,
            respBaseline: nil, sleepPerf: nil)
        let neutralScore = RecoveryScorer.recovery(
            hrv: hrvBaseline.baseline, rhr: 60.0, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: nil,
            respBaseline: nil, sleepPerf: nil)

        // Intentionally omit arg 8 (skinTempDev) to exercise the real default path from #51.
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: beyondHRV, rhr: 60.0, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: nil,
            respBaseline: nil, sleepPerf: nil)
        let scoreAfter = RecoveryScorer.recovery(
            hrv: beyondHRV, rhr: 60.0, resp: nil,
            hrvBaseline: hrvBaseline, rhrBaseline: nil,
            respBaseline: nil, sleepPerf: nil)

        XCTAssertLessThan(scoreBefore! - neutralScore!, -0.5)
        XCTAssertEqual(scoreAfter, scoreBefore)
        XCTAssertEqual(drivers, [ChargeDriver(
            label: "Heart rate variability",
            deltaPoints: -1,
            valueText: "30 ms",
            baselineText: "30 ms baseline",
            verdict: "below baseline, limiting recovery")])
    }

    // MARK: - Presence / omission

    func testColdStartHRVBaselineYieldsNoDrivers() {
        // HRV baseline not usable -> recovery() is nil -> no real contributions to attribute.
        let coldHrv = baseline(mean: 50, sigma: 6, nValid: 1)   // < seed -> .provisional? force calibrating
        let calibrating = BaselineState(baseline: 50, spread: 6 / 1.253, nValid: 1,
                                        nightsSinceUpdate: 0, status: .calibrating)
        _ = coldHrv
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 60, rhr: 50, resp: 15,
            hrvBaseline: calibrating, rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.9, skinTempDev: 0.2)
        XCTAssertTrue(drivers.isEmpty)
    }

    func testMissingTermsOmittedNotFabricated() {
        // No resp, no resp baseline, no skin temp -> those rows must be ABSENT (not zero rows).
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 60, rhr: 50, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil, sleepPerf: 0.9, skinTempDev: nil)
        let labels = Set(drivers.map { $0.label })
        XCTAssertTrue(labels.contains("Heart rate variability"))
        XCTAssertTrue(labels.contains("Resting heart rate"))
        XCTAssertTrue(labels.contains("Sleep quality"))
        XCTAssertFalse(labels.contains("Respiratory rate"))     // omitted, not a fake 0 row
        XCTAssertFalse(labels.contains("Skin temperature"))     // omitted, not a fake 0 row
        XCTAssertEqual(drivers.count, 3)
    }

    func testNoRHRBaselineOmitsRHRRow() {
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 60, rhr: 50, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: nil,
            respBaseline: nil, sleepPerf: 0.85, skinTempDev: nil)
        XCTAssertFalse(drivers.contains { $0.label == "Resting heart rate" })
        XCTAssertTrue(drivers.contains { $0.label == "Heart rate variability" })
    }

    // MARK: - Sign correctness (the term's real direction)

    func testGoodInputsGivePositiveContributions() {
        // Moderately-good inputs in the real operating range (Charge in the high 70s/low 80s, not a
        // saturated +3sigma-on-everything corner where the logistic is flat and small-weight terms
        // round to 0 points honestly). Each MATERIAL term (HRV 0.55, resting HR 0.20, Rest 0.15)
        // should push Charge UP, so its marginal-vs-neutral contribution is strictly positive.
        // Respiration is a deliberately-minor 0.05-weight term: it can legitimately be worth ~0
        // points, so we assert only its DIRECTION (non-negative + a supporting verdict), not a
        // fabricated magnitude.
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 58, rhr: 53, resp: 15,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 58, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.91, skinTempDev: nil)
        let hrv = drivers.first { $0.label == "Heart rate variability" }!
        let rhr = drivers.first { $0.label == "Resting heart rate" }!
        let sleep = drivers.first { $0.label == "Sleep quality" }!
        let resp = drivers.first { $0.label == "Respiratory rate" }!
        XCTAssertGreaterThan(hrv.deltaPoints, 0)
        XCTAssertGreaterThan(rhr.deltaPoints, 0)
        XCTAssertGreaterThan(sleep.deltaPoints, 0)
        XCTAssertGreaterThanOrEqual(resp.deltaPoints, 0)   // minor 0.05-weight term; direction below
        XCTAssertTrue(hrv.verdict.contains("supporting recovery"))
        XCTAssertTrue(rhr.verdict.contains("supporting recovery"))
        XCTAssertTrue(resp.verdict.contains("supporting recovery"))
    }

    func testBadInputsGiveNegativeContributions() {
        // HRV below baseline, RHR above, poor sleep -> each should pull Charge DOWN (<0).
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 38, rhr: 66, resp: 19,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 58, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.65, skinTempDev: nil)
        let hrv = drivers.first { $0.label == "Heart rate variability" }!
        let rhr = drivers.first { $0.label == "Resting heart rate" }!
        let sleep = drivers.first { $0.label == "Sleep quality" }!
        XCTAssertLessThan(hrv.deltaPoints, 0)
        XCTAssertLessThan(rhr.deltaPoints, 0)
        XCTAssertLessThan(sleep.deltaPoints, 0)
        XCTAssertTrue(hrv.verdict.contains("limiting recovery"))
    }

    func testSkinTempDeviationIsAlwaysNonPositive() {
        // Skin temp is a SYMMETRIC penalty: any drift can only lower Charge, so its contribution
        // (full minus without) is <= 0 for both a warm and a cold drift.
        let warm = RecoveryScorer.chargeDrivers(
            hrv: 55, rhr: 52, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil, sleepPerf: 0.85, skinTempDev: 0.8)
        let cold = RecoveryScorer.chargeDrivers(
            hrv: 55, rhr: 52, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: nil, sleepPerf: 0.85, skinTempDev: -0.8)
        let warmRow = warm.first { $0.label == "Skin temperature" }!
        let coldRow = cold.first { $0.label == "Skin temperature" }!
        XCTAssertLessThanOrEqual(warmRow.deltaPoints, 0)
        XCTAssertLessThanOrEqual(coldRow.deltaPoints, 0)
        XCTAssertTrue(warmRow.valueText.contains("+0.8"))
        XCTAssertTrue(coldRow.valueText.contains("-0.8"))
    }

    // MARK: - Ordering, value text, baseline text

    func testOrderedByMagnitudeBiggestMoverFirst() {
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 68, rhr: 49, resp: 14,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 58, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.95, skinTempDev: 0.4)
        let mags = drivers.map { abs($0.deltaPoints) }
        XCTAssertEqual(mags, mags.sorted(by: >), "drivers must be ordered biggest mover first")
        // HRV is the dominant weight; with a strong HRV signal it should lead.
        XCTAssertEqual(drivers.first?.label, "Heart rate variability")
    }

    func testValueAndBaselineTextShape() {
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 58, rhr: 61, resp: nil,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 64, sigma: 3),
            respBaseline: nil, sleepPerf: 0.85, skinTempDev: nil)
        let rhr = drivers.first { $0.label == "Resting heart rate" }!
        XCTAssertEqual(rhr.valueText, "61 bpm")
        XCTAssertEqual(rhr.baselineText, "64 bpm baseline")
        let hrv = drivers.first { $0.label == "Heart rate variability" }!
        XCTAssertEqual(hrv.valueText, "58 ms")
        XCTAssertEqual(hrv.baselineText, "50 ms baseline")
        // Sleep quality has no learned baseline -> empty baselineText (UI omits the line).
        let sleep = drivers.first { $0.label == "Sleep quality" }!
        XCTAssertEqual(sleep.baselineText, "")
    }

    func testSkinTempAndRespirationFormattingUseSharedPOSIXContract() {
        let expectedSkinText: [(Double, String)] = [
            (-0.35, "-0.4 C vs baseline"),
            (0.35, "+0.4 C vs baseline"),
            (-0.34, "-0.3 C vs baseline"),
            (0.34, "+0.3 C vs baseline"),
            (-0.36, "-0.4 C vs baseline"),
            (0.36, "+0.4 C vs baseline"),
            (-0.0, "-0.0 C vs baseline"),
            (0.0, "+0.0 C vs baseline"),
        ]

        for (deviation, expected) in expectedSkinText {
            let drivers = RecoveryScorer.chargeDrivers(
                hrv: 46, rhr: 58, resp: 14,
                hrvBaseline: baseline(mean: 51, sigma: 6.265),
                rhrBaseline: baseline(mean: 58, sigma: 5.012, nValid: 12),
                respBaseline: baseline(mean: 15, sigma: 1.8795, nValid: 12),
                sleepPerf: 0.9, skinTempDev: deviation)
            let skin = try! XCTUnwrap(drivers.first { $0.label == "Skin temperature" })
            XCTAssertEqual(skin.valueText, expected)
            XCTAssertEqual(skin.baselineText, "")
            XCTAssertLessThanOrEqual(skin.deltaPoints, 0)

            let respiration = try! XCTUnwrap(drivers.first { $0.label == "Respiratory rate" })
            XCTAssertEqual(respiration.valueText, "14.0 br/min")
            XCTAssertEqual(respiration.baselineText, "15.0 br/min baseline")
        }
    }

    func testNoEmDashesInOutput() {
        let drivers = RecoveryScorer.chargeDrivers(
            hrv: 60, rhr: 50, resp: 15,
            hrvBaseline: baseline(mean: 50, sigma: 6), rhrBaseline: baseline(mean: 55, sigma: 3),
            respBaseline: baseline(mean: 16, sigma: 2), sleepPerf: 0.9, skinTempDev: 0.3)
        for d in drivers {
            for s in [d.label, d.valueText, d.baselineText, d.verdict] {
                XCTAssertFalse(s.contains("\u{2014}"), "em-dash in: \(s)")
            }
        }
    }

    // MARK: - A5: relative skin-temp tier

    func testSkinTempRelativeNilWhenNoDeviation() {
        XCTAssertNil(RecoveryScorer.skinTempRelative(deviationC: nil))
    }

    func testSkinTempRelativeTiers() {
        let band = RecoveryScorer.skinTempTypicalBandC
        // Within the band -> typical.
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: 0.0)?.tier, .typical)
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: band)?.tier, .typical)        // boundary inclusive
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: -band)?.tier, .typical)
        // Beyond the band -> warmer / cooler.
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: band + 0.2)?.tier, .warmer)
        XCTAssertEqual(RecoveryScorer.skinTempRelative(deviationC: -(band + 0.2))?.tier, .cooler)
    }

    func testSkinTempRelativeCarriesSignedDeviation() {
        let rel = RecoveryScorer.skinTempRelative(deviationC: 0.7)!
        XCTAssertEqual(rel.deviationC, 0.7, accuracy: 1e-9)
        XCTAssertEqual(rel.tier, .warmer)
    }
}
