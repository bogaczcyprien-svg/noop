import XCTest
@testable import StrandAnalytics
import WhoopStore

/// FORK-ONLY, not ported to Android. Training and sleep parts of the week in review.
final class WeeklyRecapStatsTests: XCTestCase {

    func testWeekRunsMondayToSunday() {
        // 2026-11-15 is a Sunday.
        let w = WeeklyRecapStats.weekDays(containing: "2026-11-15")
        XCTAssertEqual(w.first, "2026-11-09")
        XCTAssertEqual(w.last, "2026-11-15")
        XCTAssertEqual(w.count, 7)
        XCTAssertEqual(WeeklyRecapStats.weekDays(containing: "2026-11-16").first, "2026-11-16")
        XCTAssertTrue(WeeklyRecapStats.weekDays(containing: "nope").isEmpty)
    }

    private func row(_ day: Int, _ sport: String, minutes: Double, km: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: day, endTs: day + Int(minutes * 60), sport: sport, source: "manual",
                   durationS: minutes * 60, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                   distanceM: km.map { $0 * 1_000 }, zonesJSON: nil, notes: nil, steps: nil)
    }

    func testTrainingCountsOnlyTheWeek() {
        // startTs doubles as an index here; dayOf maps it to a day key.
        let days = [1: "2026-11-10", 2: "2026-11-12", 3: "2026-11-12", 4: "2026-11-20"]
        let rows = [row(1, "Running", minutes: 40, km: 8), row(2, "Cycling", minutes: 90, km: 35),
                    row(3, "Running", minutes: 30, km: 6), row(4, "Running", minutes: 60)]
        let t = WeeklyRecapStats.training(rows, week: Set(WeeklyRecapStats.weekDays(containing: "2026-11-15")),
                                          dayOf: { days[$0] ?? "" })
        XCTAssertEqual(t.count, 3)
        XCTAssertEqual(t.minutes, 160, accuracy: 0.01)
        XCTAssertEqual(t.distanceKm, 49, accuracy: 0.01)
        XCTAssertEqual(t.bySport.first?.name, "Cycling")
        XCTAssertEqual(t.bySport.last, WeeklyRecapStats.Sport(name: "Running", count: 2, minutes: 70))
    }

    func testSleepAveragesTheNightsThatExist() {
        let week = Set(WeeklyRecapStats.weekDays(containing: "2026-11-15"))
        let s = WeeklyRecapStats.sleep(minutesByDay: ["2026-11-10": 420, "2026-11-11": 480, "2026-11-30": 300],
                                       efficiencyByDay: ["2026-11-10": 0.9], week: week)
        XCTAssertEqual(s?.nights, 2)
        XCTAssertEqual(s?.avgMinutes ?? 0, 450, accuracy: 0.01)
        XCTAssertEqual(s?.avgEfficiency ?? 0, 0.9, accuracy: 0.001)
        XCTAssertNil(WeeklyRecapStats.sleep(minutesByDay: [:], efficiencyByDay: [:], week: week))
    }
}
