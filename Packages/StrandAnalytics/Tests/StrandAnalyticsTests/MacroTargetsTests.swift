import XCTest
@testable import StrandAnalytics

/// FORK-ONLY, not ported to Android. Pure-function tests for MacroTargets — the daily protein/carb/fat
/// target math behind the Nutrition tab. Mirrors HydrationGoalTests.swift's shape.
final class MacroTargetsTests: XCTestCase {

    // MARK: - Per-kg rate scaling with Effort

    func testProteinGPerKgScalesWithEffort() {
        XCTAssertEqual(MacroTargets.proteinGPerKg(effort: 0), 1.6, accuracy: 1e-9)
        XCTAssertEqual(MacroTargets.proteinGPerKg(effort: 100), 2.2, accuracy: 1e-9)
        XCTAssertEqual(MacroTargets.proteinGPerKg(effort: 50), 1.9, accuracy: 1e-9)
    }

    func testCarbGPerKgScalesWithEffort() {
        XCTAssertEqual(MacroTargets.carbGPerKg(effort: 0), 3.0, accuracy: 1e-9)
        XCTAssertEqual(MacroTargets.carbGPerKg(effort: 100), 8.0, accuracy: 1e-9)
        XCTAssertEqual(MacroTargets.carbGPerKg(effort: 50), 5.5, accuracy: 1e-9)
    }

    func testEffortOutOfRangeClamps() {
        // A caller-supplied Effort outside 0...100 must clamp, never extrapolate past the cited ranges.
        XCTAssertEqual(MacroTargets.proteinGPerKg(effort: 150), MacroTargets.proteinGPerKg(effort: 100),
                       accuracy: 1e-9)
        XCTAssertEqual(MacroTargets.carbGPerKg(effort: -10), MacroTargets.carbGPerKg(effort: 0), accuracy: 1e-9)
    }

    func testNilEffortFallsBackToRestDayBaseline() {
        // No Effort yet today -> the rest-day (Effort 0) baseline, never a fabricated bump.
        XCTAssertEqual(MacroTargets.proteinGPerKg(effort: nil), MacroTargets.proteinGPerKg(effort: 0),
                       accuracy: 1e-9)
        XCTAssertEqual(MacroTargets.carbGPerKg(effort: nil), MacroTargets.carbGPerKg(effort: 0), accuracy: 1e-9)
    }

    func testNonFiniteEffortTreatedAsNil() {
        XCTAssertEqual(MacroTargets.proteinGPerKg(effort: .nan), MacroTargets.proteinGPerKg(effort: 0),
                       accuracy: 1e-9)
        XCTAssertEqual(MacroTargets.proteinGPerKg(effort: .infinity), MacroTargets.proteinGPerKg(effort: 0),
                       accuracy: 1e-9)
    }

    // MARK: - Rounding

    func testRoundsToNearest5g() {
        XCTAssertEqual(MacroTargets.roundToNearest(127, step: 5), 125)
        XCTAssertEqual(MacroTargets.roundToNearest(128, step: 5), 130)
        XCTAssertEqual(MacroTargets.roundToNearest(0, step: 5), 0)
    }

    // MARK: - kcal(proteinG:carbsG:fatG:) — the shared Atwater conversion

    func testKcalUsesAtwaterFactors() {
        XCTAssertEqual(MacroTargets.kcal(proteinG: 100, carbsG: 0, fatG: 0), 400, accuracy: 1e-9)
        XCTAssertEqual(MacroTargets.kcal(proteinG: 0, carbsG: 100, fatG: 0), 400, accuracy: 1e-9)
        XCTAssertEqual(MacroTargets.kcal(proteinG: 0, carbsG: 0, fatG: 100), 900, accuracy: 1e-9)
    }

    // MARK: - dailyTargets(weightKg:effort:dailyEnergyKcal:) — worked examples (pinned to the exact gram)

    func testNormalDayWorkedExample() {
        // weight 75kg, effort 20, energy 2200 -> protein 130g, carbs 300g, fat 55g (floor not triggered).
        let t = MacroTargets.dailyTargets(weightKg: 75, effort: 20, dailyEnergyKcal: 2200)
        XCTAssertEqual(t.proteinG, 130)
        XCTAssertEqual(t.carbsG, 300)
        XCTAssertEqual(t.fatG, 55)
    }

    func testFatFloorTriggersOnHighProteinCarbDay() {
        // weight 75kg, effort 65, energy 2600 -> protein 150g, carbs 470g leave only 120kcal remainder
        // (13.3g fat), well under the 20%-of-2600=520kcal (57.8g) floor -> the floor wins at 60g.
        let t = MacroTargets.dailyTargets(weightKg: 75, effort: 65, dailyEnergyKcal: 2600)
        XCTAssertEqual(t.proteinG, 150)
        XCTAssertEqual(t.carbsG, 470)
        XCTAssertEqual(t.fatG, 60)
    }

    func testNilEffortAndNilEnergyWorkedExample() {
        // weight 75kg, no Effort yet, no day-energy estimate yet -> rest-day protein/carb baselines,
        // energy falls back to weightKg*30 = 2250kcal, fat is the (unfloored) remainder, 95g.
        let t = MacroTargets.dailyTargets(weightKg: 75, effort: nil, dailyEnergyKcal: nil)
        XCTAssertEqual(t.proteinG, 120)
        XCTAssertEqual(t.carbsG, 225)
        XCTAssertEqual(t.fatG, 95)
    }

    func testNonPositiveWeightYieldsZeroProteinAndCarbs() {
        // No usable weight: protein/carbs can't scale off it (never a fabricated gram figure), but fat
        // still floors against a supplied energy figure.
        let t = MacroTargets.dailyTargets(weightKg: 0, effort: 50, dailyEnergyKcal: 2000)
        XCTAssertEqual(t.proteinG, 0)
        XCTAssertEqual(t.carbsG, 0)
        XCTAssertGreaterThan(t.fatG, 0)
    }

    func testNonPositiveWeightAndNoEnergyYieldsAllZero() {
        let t = MacroTargets.dailyTargets(weightKg: -5, effort: 50, dailyEnergyKcal: nil)
        XCTAssertEqual(t.proteinG, 0)
        XCTAssertEqual(t.carbsG, 0)
        XCTAssertEqual(t.fatG, 0)
    }

    func testTotalKcalMatchesTheThreeGramFigures() {
        let t = MacroTargets.dailyTargets(weightKg: 75, effort: 20, dailyEnergyKcal: 2200)
        XCTAssertEqual(t.totalKcal,
                       Int((MacroTargets.kcal(proteinG: Double(t.proteinG), carbsG: Double(t.carbsG),
                                              fatG: Double(t.fatG))).rounded()))
    }

    func testHigherEffortNeverLowersProteinOrCarbTargets() {
        // Monotonic in Effort: a harder day must never ask for LESS protein/carb than an easier one,
        // same weight/energy held fixed.
        let rest = MacroTargets.dailyTargets(weightKg: 70, effort: 0, dailyEnergyKcal: 2000)
        let hard = MacroTargets.dailyTargets(weightKg: 70, effort: 90, dailyEnergyKcal: 2000)
        XCTAssertGreaterThanOrEqual(hard.proteinG, rest.proteinG)
        XCTAssertGreaterThanOrEqual(hard.carbsG, rest.carbsG)
    }
}
