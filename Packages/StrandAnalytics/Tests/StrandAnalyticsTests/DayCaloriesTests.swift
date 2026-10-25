import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests Calories.estimateDayCalories — the APPROXIMATE whole-day HR-only energy estimate
/// (Keytel active + Harris–Benedict BMR) that backs DailyMetric.activeKcalEst for BLE-only
/// users. Pure-function tests; no DB. Not cloud/clinical parity. Mirrors the Android
/// DayCaloriesTest vectors value-for-value.
final class DayCaloriesTests: XCTestCase {

    private func hrDay(bpm: Int, n: Int, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testDayCaloriesEmptyIsZero() {
        XCTAssertEqual(
            Calories.estimateDayCalories([], profile: UserProfile(), hrmax: 190.0, restingHR: 55.0),
            0.0, accuracy: 1e-12)
    }

    func testDayEnergyEmptyComponentsAreZero() {
        let estimate = Calories.estimateDayEnergy([], profile: UserProfile(),
                                                  hrmax: 190.0, restingHR: 55.0)
        XCTAssertEqual(estimate.restingKcal, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.lightKcal, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.activeKcal, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.totalKcal, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.observedSeconds, 0, accuracy: 1e-12)
    }

    func testDayCaloriesMatchesBoutAtOneHz() {
        // At a steady 1 Hz stream the day and bout estimators agree exactly: the bout path's
        // elapsed-time weighting caps every ~1 s interval at 1 s, so it collapses to the day
        // path's flat one-second-per-sample. They diverge on gappy streams, but not here. The day
        // total adds the thermic effect of food; 130 bpm is above the gate, so there is no light zone.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let hr = hrDay(bpm: 130, n: 600)  // 10 min above the active threshold, dense 1 Hz
        let day = Calories.estimateDayCalories(hr, profile: profile, hrmax: 185.0, restingHR: 55.0)
        let bout = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        XCTAssertEqual(day, bout * (1.0 + Calories.dayThermicEffectFraction), accuracy: 1e-9)
    }

    func testGaplessOneHzDayMatchesLegacyTotal() {
        // Pin the pre-change 1 Hz result so the sparse-cadence fix cannot silently move WHOOP 4
        // totals. This mixed full day exercises the resting floor, the light zone (the 70 bpm block)
        // and the gross active rate.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let block = 8 * 3_600
        let day = hrDay(bpm: 55, n: block)
            + hrDay(bpm: 130, n: block, start: block)
            + hrDay(bpm: 70, n: block, start: 2 * block)
        let total = Calories.estimateDayCalories(day, profile: profile,
                                                 hrmax: 185.0, restingHR: 55.0)
        // The legacy estimator on main measured 6774.323772067612; its per-sample summation differs
        // from the R × N association by ~6.6e-9 kcal, so keep tolerance above that rounding noise.
        // Plus the light zone, BMR/86400 × (0.3 + 0.7 × 5/55) × 28800 = 221.242060606, then × 1.1 for
        // the thermic effect of food, computed by hand from the constants.
        XCTAssertEqual(total, 7_695.122415941, accuracy: 1e-6,
                       "a gapless 1 Hz day must equal the legacy estimator plus light zone and digestion")
    }

    func testDayCaloriesRestingDayIsLowerThanActiveDay() {
        // A whole day at resting HR burns far less than the same length all-active day,
        // and the resting-day total is positive (BMR floor).
        let profile = UserProfile(weightKg: 70, heightCm: 170, age: 30, sex: "nonbinary")
        // Day activeThreshold = 55 + 0.50*(185-55) = 120 bpm; 60 < 120 (resting), 150 >= 120 (active).
        let restingDay = Calories.estimateDayCalories(hrDay(bpm: 60, n: 3600), profile: profile,
                                                      hrmax: 185.0, restingHR: 55.0)
        let activeDay = Calories.estimateDayCalories(hrDay(bpm: 150, n: 3600), profile: profile,
                                                     hrmax: 185.0, restingHR: 55.0)
        XCTAssertGreaterThan(restingDay, 0.0, "resting day must burn > 0 (BMR floor)")
        XCTAssertGreaterThan(activeDay, restingDay, "active day must exceed resting day")
    }

    func testFullDayAtRestingHRIsBMRPlusDigestion() {
        // A full 24 h AT resting HR (below the light-zone floor) totals the subject's BMR plus the
        // 10% thermic effect of food. Standard male test subject's revised Harris–Benedict BMR ≈
        // 1825.25 kcal, so ≈ 2007.77. This is an APPROXIMATE estimate, not medical advice.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let sedentary = hrDay(bpm: 55, n: 86_400)   // 24 h, all at resting HR
        let total = Calories.estimateDayCalories(sedentary, profile: profile,
                                                 hrmax: 185.0, restingHR: 55.0)
        XCTAssertEqual(total, 2007.77, accuracy: 1.0,
                       "a full day at resting HR must total ≈ BMR × 1.1 (~2008 kcal)")
    }

    /// The fork report: an awake office day (8 h asleep at resting HR, 16 h awake around 70-75 bpm)
    /// read about the sleeping BMR. The awake hours now earn the light zone, so the day lands at a
    /// sedentary PAL of about 1.4 (≈ 2537 kcal), not 1.0.
    func testAwakeOfficeDayIsWellAboveBMR() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let block = 8 * 3_600
        let day = hrDay(bpm: 55, n: block) + hrDay(bpm: 70, n: block, start: block)
            + hrDay(bpm: 75, n: block, start: 2 * block)
        let e = Calories.estimateDayEnergy(day, profile: profile, hrmax: 185.0, restingHR: 55.0)
        XCTAssertEqual(e.restingKcal, 1825.247, accuracy: 1e-6)
        XCTAssertGreaterThan(e.lightKcal, 400)
        XCTAssertEqual(e.activeKcal, 0, accuracy: 1e-12)
        XCTAssertTrue((2300.0...2600.0).contains(e.totalKcal), "office day total \(e.totalKcal)")
    }

    func testLightActivityDayIsFarBelowOldInflatedTotal() {
        // The bug: at the OLD 30% day gate (~94 bpm for this subject) ordinary low-intensity
        // daytime HR (~100 bpm walking/standing) was credited the FULL Keytel gross-exercise
        // rate, inflating the day total by ~1000+ kcal. The 50% day gate (120 bpm) now treats
        // that HR as light activity, so a realistic mixed light day (8 h sleep @55, 8 h sedentary
        // @70, 8 h light activity @100) earns the light zone instead of the old runaway figure.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let block = 8 * 3_600
        let lightDay = hrDay(bpm: 55, n: block)
            + hrDay(bpm: 70, n: block, start: block)
            + hrDay(bpm: 100, n: block, start: 2 * block)
        let total = Calories.estimateDayCalories(lightDay, profile: profile,
                                                 hrmax: 185.0, restingHR: 55.0)
        // (BMR 1825.247 + light 221.242 @70 + light 453.546 @100) × 1.1, by hand from the constants.
        XCTAssertEqual(total, 2750.04, accuracy: 1.0,
                       "a light-activity day must land at BMR plus the light zone, not the old inflated total")
        // Teeth: the OLD 30%-gate model credited the 8 h @100 bpm block at the full Keytel
        // active rate (~3551 kcal for that block alone), so the old day total was ≈ 4768 kcal.
        // Pin that we are now WELL below it (more than 2000 kcal lower).
        XCTAssertLessThan(total, 4768.0 - 2000.0,
                          "the light-activity day must drop far below the old inflated ~4768 kcal")
    }

    func testSparseHRTracksElapsedTimeNotSampleCount() {
        // A 10-minute effort at a steady active HR, sampled two ways over the SAME ~600 s span:
        // densely at 1 Hz, and sparsely at one sample / 10 s (the WHOOP 5/MG case). Energy must
        // track elapsed time, so the sparse estimate lands close to the dense one — NOT ~1/10th
        // of it, as the old one-second-per-sample count produced. (BOUT path only.)
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let dense = (0..<600).map { HRSample(ts: $0, bpm: 130) }
        let sparse = stride(from: 0, to: 600, by: 10).map { HRSample(ts: $0, bpm: 130) }
        let denseKcal = Calories.estimateBoutCalories(dense, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        let sparseKcal = Calories.estimateBoutCalories(sparse, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        XCTAssertEqual(sparseKcal, denseKcal, accuracy: denseKcal * 0.05,
                       "sparse HR must be counted over elapsed time, not undercounted per sample")
        // Teeth: a per-sample count (60 samples) would be ~1/10th of the dense total.
        XCTAssertGreaterThan(sparseKcal, denseKcal * 0.5)
    }

    func testSparseDayCaloriesTrackElapsedTimeNotSampleCount() {
        // The daily path must be cadence-invariant too: WHOOP 5/MG's ~30 s HR and a 1 Hz
        // stream over the same ten active minutes represent the same elapsed work.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let dense = (0..<600).map { HRSample(ts: $0, bpm: 130) }
        let sparse = stride(from: 0, to: 600, by: 30).map { HRSample(ts: $0, bpm: 130) }
        let denseEnergy = Calories.estimateDayEnergy(dense, profile: profile,
                                                     hrmax: 185.0, restingHR: 55.0)
        let sparseEnergy = Calories.estimateDayEnergy(sparse, profile: profile,
                                                      hrmax: 185.0, restingHR: 55.0)
        XCTAssertEqual(sparseEnergy.observedSeconds, 600, accuracy: 1e-12)
        XCTAssertEqual(sparseEnergy.restingKcal, denseEnergy.restingKcal, accuracy: 1e-9)
        XCTAssertEqual(sparseEnergy.activeKcal, denseEnergy.activeKcal, accuracy: 1e-9)
        XCTAssertEqual(sparseEnergy.totalKcal, denseEnergy.totalKcal, accuracy: 1e-9)
    }

    func testDayEnergyParityVectorOracle() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let vectors = [
            hrDay(bpm: 55, n: 86_400),
            (0..<600).map { HRSample(ts: $0, bpm: 130) },
            stride(from: 0, to: 600, by: 30).map { HRSample(ts: $0, bpm: 130) },
            [HRSample(ts: 0, bpm: 130), HRSample(ts: 3600, bpm: 130)],
        ].map { Calories.estimateDayEnergy($0, profile: profile, hrmax: 185, restingHR: 55) }
        // Generated from the Swift implementation and copied verbatim to Android's parity test. None of
        // these vectors reaches the light zone (55 is resting HR, 130 is above the gate); the totals are
        // the old ones × 1.1 for the thermic effect of food.
        let expected: [(resting: Double, active: Double, total: Double, seconds: Double)] = [
            (1825.247000000000, 0.000000000000, 2007.771700000000, 86_400.0),
            (12.675326388889, 103.105766084605, 127.359201720843, 600.0),
            (12.675326388889, 103.105766084603, 127.359201720841, 600.0),
            (2.535065277778, 20.621153216921, 25.471840344169, 120.0),
        ]
        for (value, oracle) in zip(vectors, expected) {
            XCTAssertEqual(value.lightKcal, 0, accuracy: 1e-12)
            XCTAssertEqual(value.restingKcal, oracle.resting, accuracy: 1e-9)
            XCTAssertEqual(value.activeKcal, oracle.active, accuracy: 1e-9)
            XCTAssertEqual(value.totalKcal, oracle.total, accuracy: 1e-9)
            XCTAssertEqual(value.observedSeconds, oracle.seconds, accuracy: 1e-9)
        }
    }

    func testWearGapIsCappedNotCreditedInFull() {
        // Two active samples an hour apart must NOT credit a full hour of active burn — the
        // per-sample interval is capped at mergeGapS (150 s). The pre-gap sample contributes
        // 150 s and the tail 1 s, so the total equals a 151 s continuous equivalent, not 3600 s.
        // (BOUT path only.)
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let gapped = [HRSample(ts: 0, bpm: 130), HRSample(ts: 3600, bpm: 130)]
        let cappedEquiv = (0...150).map { HRSample(ts: $0, bpm: 130) }   // 151 s continuous
        let gappedKcal = Calories.estimateBoutCalories(gapped, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        let equivKcal = Calories.estimateBoutCalories(cappedEquiv, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        XCTAssertEqual(gappedKcal, equivKcal, accuracy: equivKcal * 0.001,
                       "an inter-sample gap must be capped at mergeGapS, not credited in full")
    }

    func testDayPathCapsRestingAndActiveGap() {
        // Two isolated high readings must not claim the whole hour as either resting or active
        // energy. With the 60 s carry cap, both components cover exactly 120 supported seconds.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let gapped = [HRSample(ts: 0, bpm: 130), HRSample(ts: 3600, bpm: 130)]
        let active120s = hrDay(bpm: 130, n: 120)
        let active3660s = hrDay(bpm: 130, n: 3660)
        let gapEnergy = Calories.estimateDayEnergy(gapped, profile: profile,
                                                   hrmax: 185.0, restingHR: 55.0)
        let shortEnergy = Calories.estimateDayEnergy(active120s, profile: profile,
                                                     hrmax: 185.0, restingHR: 55.0)
        let continuousEnergy = Calories.estimateDayEnergy(active3660s, profile: profile,
                                                          hrmax: 185.0, restingHR: 55.0)
        XCTAssertEqual(gapEnergy.observedSeconds, 120, accuracy: 1e-12)
        XCTAssertEqual(gapEnergy.restingKcal, shortEnergy.restingKcal, accuracy: 1e-9,
                       "a long gap must carry only 120 capped resting seconds")
        XCTAssertEqual(gapEnergy.activeKcal, shortEnergy.activeKcal, accuracy: 1e-9,
                       "a long gap must carry only 120 capped active seconds")
        XCTAssertEqual(gapEnergy.totalKcal, shortEnergy.totalKcal, accuracy: 1e-9)
        XCTAssertLessThan(gapEnergy.totalKcal, continuousEnergy.totalKcal,
                          "a sensor gap must not be treated as continuous exercise")
    }

    // A timestamp safely inside UTC day 2026-01-02 (2026-01-02T12:00:00Z).
    private let dayUtc = "2026-01-02"
    private let noonUtc = 1_767_355_200

    private func hr(_ tsOffsetSec: Int, _ bpm: Int) -> HRSample {
        HRSample(ts: noonUtc + tsOffsetSec, bpm: bpm)
    }

    func testAnalyzeDayCaloriesIgnoreAdjacentDayHr() throws {
        // analyzeDay must filter HR to the target UTC day before summing calories — the
        // IntelligenceEngine read window spans ~42h, so adjacent-day HR must NOT inflate the
        // day's activeKcalEst (the critical "full-window double-count" regression).
        let inDay = (0..<600).map { hr($0, 120) }
        // Same in-day HR plus 600 samples ~36h earlier (a different UTC day, inside the window).
        let withAdjacent = inDay + (0..<600).map { hr(-36 * 3_600 - $0, 120) }
        let a = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: inDay, profile: UserProfile()).daily.activeKcalEst)
        let b = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: withAdjacent, profile: UserProfile()).daily.activeKcalEst)
        XCTAssertEqual(a, b, accuracy: 1e-6, "adjacent-day HR must not change the day's calories")
    }

    func testAnalyzeDayDayHrCoversFullCalendarDay() throws {
        // Simulate the past-day clip: the night-window HR only reaches midday; the full
        // calendar-day HR also has the afternoon. activeKcalEst must use dayHr when supplied,
        // so the full-day total exceeds the clipped night-window total (the undercount fix).
        let nightWindow = (0..<600).map { hr($0, 120) }
        let fullDay = nightWindow + (0..<600).map { hr(3 * 3_600 + $0, 120) }
        let clipped = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: nightWindow, profile: UserProfile()).daily.activeKcalEst)
        let full = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: nightWindow, dayHr: fullDay, profile: UserProfile()).daily.activeKcalEst)
        XCTAssertGreaterThan(full, clipped,
                             "full calendar-day calories must exceed the clipped night-window total")
    }

    func testAnalyzeDayDayHrNilFallsBackToWindowHr() throws {
        // With no calendar-day stream, the total falls back to the window `hr` — identical to
        // passing that same window explicitly as dayHr (the (dayHr ?? hr) fallback).
        let window = (0..<600).map { hr($0, 120) }
        let fallback = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: window, profile: UserProfile()).daily.activeKcalEst)
        let explicit = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: window, dayHr: window, profile: UserProfile()).daily.activeKcalEst)
        XCTAssertEqual(fallback, explicit, accuracy: 1e-9)
    }

    /// A dropout in an otherwise dense day carries RESTING energy across the gap but not ACTIVE energy.
    ///
    /// Active duration is capped at the inferred cadence (1 s here), so the two dense blocks credit
    /// exactly as much active energy as one continuous block of the same sample count — no magic
    /// number, just the invariant. Resting is capped at the wider `dayMaxObservedGapS` and so DOES
    /// grow, which is the intended asymmetry: metabolism continues across a gap, exercise is not
    /// evidenced by one. Capping active at 60 s instead would have credited the reading before the gap
    /// with a full minute of exercise it never demonstrated. Twin of the Kotlin test.
    func testDropoutInADenseDayCarriesRestingButNotActive() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let gapped = hrDay(bpm: 130, n: 120, start: 0) + hrDay(bpm: 130, n: 120, start: 200)
        let continuous = hrDay(bpm: 130, n: 240)
        let g = Calories.estimateDayEnergy(gapped, profile: profile, hrmax: 185, restingHR: 55)
        let c = Calories.estimateDayEnergy(continuous, profile: profile, hrmax: 185, restingHR: 55)
        XCTAssertEqual(g.activeKcal, c.activeKcal, accuracy: 1e-9,
                       "active energy must not grow across a sensor gap")
        XCTAssertGreaterThan(g.restingKcal, c.restingKcal, "resting energy SHOULD carry across the gap")
        XCTAssertLessThan(g.observedSeconds, 240.0 + 81.0, "but only as far as the observed-gap cap")
    }

    /// Two readings in the same second are reachable — `hrSample` is keyed (deviceId, ts) and the day
    /// feed unions devices, so a two-strap day has one per strap. Only the LAST of a tied run receives
    /// the interval, so without a tiebreak the day's active energy depended on the order the feed
    /// happened to arrive in, and on a sort stability Swift does not guarantee.
    ///
    /// Pinned twice: the result must not depend on input order, and a tie must hand the interval to the
    /// LOWER reading. Twin of the Kotlin test.
    func testTiedTimestampsAreOrderIndependentAndResolveToTheLowerReading() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let tied = [HRSample(ts: 0, bpm: 150), HRSample(ts: 0, bpm: 60), HRSample(ts: 60, bpm: 60)]
        let forward = Calories.estimateDayEnergy(tied, profile: profile, hrmax: 185, restingHR: 55)
        let reversed = Calories.estimateDayEnergy(tied.reversed(), profile: profile, hrmax: 185, restingHR: 55)
        XCTAssertEqual(forward.activeKcal, reversed.activeKcal, accuracy: 1e-12,
                       "feed order must not change the day's energy")
        XCTAssertEqual(forward.restingKcal, reversed.restingKcal, accuracy: 1e-12)
        XCTAssertEqual(forward.activeKcal, 0.0, accuracy: 1e-12,
                       "the tie resolves to the lower reading, so no active energy is credited")
    }

    // MARK: - excludedCalorieWindows (FORK-ONLY, not ported to Android)

    func testExcludedCalorieWindowReplacesHrEstimateWithImportedKcal() throws {
        // The whole day's HR falls inside the window => the generic Keytel estimate is dropped
        // entirely and the day total is exactly the imported (e.g. intervals.icu) kcal.
        let profile = UserProfile()
        let samples = (0..<600).map { hr($0, 150) }
        let total = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: samples,
            excludedCalorieWindows: [(start: noonUtc, end: noonUtc + 600, kcal: 500.0)],
            profile: profile).daily.activeKcalEst)
        XCTAssertEqual(total, 500.0, accuracy: 1e-9,
                       "with the whole day's HR excluded, the total must be exactly the imported kcal")
    }

    func testExcludedCalorieWindowAddsImportedKcalAlongsideRemainingHr() throws {
        // Only the "ride" portion of the day is excluded; the rest of the day keeps its own
        // Keytel estimate, and the ride's imported kcal is added on top of it (not instead of it).
        let profile = UserProfile()
        let rideWindow = (0..<300).map { hr($0, 150) }
        let restOfDay = (0..<300).map { hr(1_000 + $0, 90) }
        let restOnlyKcal = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: restOfDay, profile: profile).daily.activeKcalEst)
        let total = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: rideWindow + restOfDay,
            excludedCalorieWindows: [(start: noonUtc, end: noonUtc + 300, kcal: 500.0)],
            profile: profile).daily.activeKcalEst)
        XCTAssertEqual(total, restOnlyKcal + 500.0, accuracy: 1e-9,
                       "the excluded window's HR estimate must be replaced by its imported kcal, added "
                       + "to the rest of the day's own estimate")
    }

    func testExcludedCalorieWindowEndIsExclusive() throws {
        // A sample exactly AT the window's end boundary is NOT excluded (half-open [start, end)),
        // matching the convention `excludedStepWindows` and a workout's own [startTs, endTs) use.
        let profile = UserProfile()
        let keptOnly = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: [hr(100, 150)], profile: profile).daily.activeKcalEst)
        let total = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: [hr(0, 150), hr(100, 150)],
            excludedCalorieWindows: [(start: noonUtc, end: noonUtc + 100, kcal: 42.0)],
            profile: profile).daily.activeKcalEst)
        XCTAssertEqual(total, keptOnly + 42.0, accuracy: 1e-9)
    }

    func testNoExcludedCalorieWindowsIsByteIdenticalToDefault() {
        // Empty (the default) must leave every existing caller's total untouched.
        let profile = UserProfile()
        let samples = (0..<600).map { hr($0, 130) }
        let withEmpty = AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: samples, excludedCalorieWindows: [], profile: profile).daily.activeKcalEst
        let withoutParam = AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: samples, profile: profile).daily.activeKcalEst
        XCTAssertEqual(withEmpty, withoutParam)
    }
}
