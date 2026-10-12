import XCTest
@testable import StrandAnalytics

/// FORK-ONLY, not ported to Android. `NutritionRecoveryInsights` is a thin ranking wrapper around
/// `CorrelationEngine.lagged` — these tests mirror `CorrelationEngineTests`' golden-value style for
/// the underlying math, plus the ranking/filtering behavior this wrapper adds.
final class NutritionRecoveryInsightsTests: XCTestCase {

    /// carbs_g[day] perfectly predicts recovery[day+1] (r=1): recovery = 0.5*carbs + 10, shifted a day.
    private let carbsRows: [(day: String, value: Double)] = [
        ("2026-01-01", 100), ("2026-01-02", 150), ("2026-01-03", 200),
        ("2026-01-04", 250), ("2026-01-05", 300), ("2026-01-06", 350),
    ]
    private let recoveryRows: [(day: String, value: Double)] = [
        ("2026-01-02", 60), ("2026-01-03", 85), ("2026-01-04", 110),
        ("2026-01-05", 135), ("2026-01-06", 160), ("2026-01-07", 185),
    ]
    /// Zero variance — every day the same — so `pearson` (and therefore `lagged`) returns nil.
    private let constProteinRows: [(day: String, value: Double)] = [
        ("2026-01-01", 50), ("2026-01-02", 50), ("2026-01-03", 50),
        ("2026-01-04", 50), ("2026-01-05", 50), ("2026-01-06", 50),
    ]

    func testInsightsRanksStrongestAbsoluteRFirst() {
        let out = NutritionRecoveryInsights.insights(
            series: ["carbs_g": carbsRows, "protein_g": constProteinRows],
            recovery: recoveryRows, lagDays: 1)

        // protein_g has zero variance -> filtered out entirely, never a spurious r.
        XCTAssertEqual(out.map(\.metricKey), ["carbs_g"])
        XCTAssertEqual(out[0].correlation.r, 1.0, accuracy: 1e-9)
        XCTAssertEqual(out[0].correlation.n, 6)
    }

    func testRanksTwoRealSeriesByAbsoluteRDescending() {
        // fat_g: a much weaker (but real) lagged relationship than carbs_g's perfect one.
        let fatRows: [(day: String, value: Double)] = [
            ("2026-01-01", 40), ("2026-01-02", 45), ("2026-01-03", 38),
            ("2026-01-04", 50), ("2026-01-05", 36), ("2026-01-06", 52),
        ]
        let out = NutritionRecoveryInsights.insights(
            series: ["carbs_g": carbsRows, "fat_g": fatRows], recovery: recoveryRows, lagDays: 1)

        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].metricKey, "carbs_g")
        XCTAssertTrue(abs(out[0].correlation.r) >= abs(out[1].correlation.r))
    }

    func testDefaultLagIsOneDay() {
        let withDefault = NutritionRecoveryInsights.insights(series: ["carbs_g": carbsRows], recovery: recoveryRows)
        let explicit = NutritionRecoveryInsights.insights(series: ["carbs_g": carbsRows], recovery: recoveryRows, lagDays: 1)
        XCTAssertEqual(withDefault, explicit)
    }

    func testEmptySeriesReturnsEmpty() {
        XCTAssertEqual(NutritionRecoveryInsights.insights(series: [:], recovery: recoveryRows), [])
    }

    func testTooFewLaggedPairsOmitted() {
        // Only 2 days of carbs data -> at most 2 lag-matched pairs, below `pearson`'s n>=3 floor.
        let short: [(day: String, value: Double)] = [("2026-01-01", 100), ("2026-01-02", 150)]
        let out = NutritionRecoveryInsights.insights(series: ["carbs_g": short], recovery: recoveryRows, lagDays: 1)
        XCTAssertEqual(out, [])
    }

    func testNoOverlapAfterShiftReturnsEmpty() {
        // recovery has no days at all 1 past any carbs day -> zero lag-matched pairs.
        let farRecovery: [(day: String, value: Double)] = [("2099-01-01", 50)]
        let out = NutritionRecoveryInsights.insights(series: ["carbs_g": carbsRows], recovery: farRecovery, lagDays: 1)
        XCTAssertEqual(out, [])
    }
}
