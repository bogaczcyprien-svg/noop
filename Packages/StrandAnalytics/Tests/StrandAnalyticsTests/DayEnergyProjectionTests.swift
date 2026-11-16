import XCTest
@testable import StrandAnalytics

/// FORK-ONLY, not ported to Android. The Nutrition tab's whole-day energy target.
final class DayEnergyProjectionTests: XCTestCase {

    func testNoEstimateYetIsTheBaseDay() {
        XCTAssertEqual(DayEnergyProjection.projectedDayKcal(burnedSoFarKcal: nil, baseDayKcal: 2300,
                                                            secondsLeftInDay: 50_000), 2300)
    }

    func testQuietMorningStaysAtTheBaseDay() {
        // 9 am, 700 kcal so far: 700 + 15 h x 95.8 = 2137 -> the base day wins.
        XCTAssertEqual(DayEnergyProjection.projectedDayKcal(burnedSoFarKcal: 700, baseDayKcal: 2300,
                                                            secondsLeftInDay: 15 * 3600), 2300)
    }

    func testAWorkoutRaisesTheTarget() {
        // 6 pm, 2100 kcal so far after a session: 2100 + 6 h x 2300 / 24 = 2675.
        XCTAssertEqual(DayEnergyProjection.projectedDayKcal(burnedSoFarKcal: 2100, baseDayKcal: 2300,
                                                            secondsLeftInDay: 6 * 3600), 2675, accuracy: 0.01)
    }

    func testBaseIsClampedToTheAllowedRange() {
        XCTAssertEqual(DayEnergyProjection.projectedDayKcal(burnedSoFarKcal: nil, baseDayKcal: 100,
                                                            secondsLeftInDay: 0), 1200)
        XCTAssertEqual(DayEnergyProjection.projectedDayKcal(burnedSoFarKcal: nil, baseDayKcal: 9_000,
                                                            secondsLeftInDay: 0), 4500)
    }
}
