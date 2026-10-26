import XCTest
@testable import StrandAnalytics

final class BreathingHistoryTests: XCTestCase {

    private let day = 86_400
    private let t0 = 1_760_000_000

    private func entry(_ i: Int, coherence: Double?, hr: Double? = 60, free: Double? = 64, seconds: Int = 300) -> BreathingHistory.Entry {
        .init(ts: t0 + i * day, exerciseId: "science_coherence_5_5", guidedSeconds: seconds, avgCoherence: coherence,
              avgHR: hr, freeAvgHR: free, rmssd: 40, breathsPerMin: 6)
    }

    func testShortSessionsAreNotKeptAndTheListIsCapped() {
        XCTAssertEqual(BreathingHistory.appending(entry(0, coherence: 50, seconds: 30), to: []), [])
        var list: [BreathingHistory.Entry] = []
        for i in 0..<(BreathingHistory.maxEntries + 5) { list = BreathingHistory.appending(entry(i, coherence: 50), to: list) }
        XCTAssertEqual(list.count, BreathingHistory.maxEntries)
        XCTAssertEqual(list.first?.ts, t0 + 5 * day)
    }

    func testTrendComparesTheLastSevenWithTheSevenBefore() throws {
        let entries = (0..<14).map { entry($0, coherence: $0 < 7 ? 40 : 60) }
        let t = try XCTUnwrap(BreathingHistory.trend(entries) { $0.avgCoherence })
        XCTAssertEqual(t.recent, 60, accuracy: 1e-9)
        XCTAssertEqual(t.previous, 40, accuracy: 1e-9)
        // Sessions without the value are skipped, and the trend waits for both halves.
        XCTAssertNil(BreathingHistory.trend(Array(entries.prefix(13))) { $0.avgCoherence })
        XCTAssertNil(BreathingHistory.trend(entries.map { entry(($0.ts - t0) / day, coherence: nil) }) { $0.avgCoherence })
    }

    func testHeartRateChangeIsExerciseMinusFree() {
        XCTAssertEqual(entry(0, coherence: 50, hr: 58, free: 66).hrChange, -8)
        XCTAssertNil(entry(0, coherence: 50, hr: 58, free: nil).hrChange)
    }

    func testStreakCountsConsecutiveDaysEndingTodayOrYesterday() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let entries = [0, 1, 2, 4, 5, 6].map { entry($0, coherence: 50) }
        let today = Date(timeIntervalSince1970: TimeInterval(t0 + 6 * day + 3_600))
        XCTAssertEqual(BreathingHistory.streakDays(entries, now: today, calendar: cal), 3)
        let tomorrow = today.addingTimeInterval(TimeInterval(day))
        XCTAssertEqual(BreathingHistory.streakDays(entries, now: tomorrow, calendar: cal), 3)
        let later = today.addingTimeInterval(TimeInterval(2 * day))
        XCTAssertEqual(BreathingHistory.streakDays(entries, now: later, calendar: cal), 0)
        XCTAssertEqual(BreathingHistory.sessionsLast7Days(entries, now: today), 6)
    }
}
