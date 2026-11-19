import XCTest
@testable import StrandAnalytics

final class HistoryStallMonitorTests: XCTestCase {
    let now = 2_000_000_000

    func testNotConnectedWhenNoRecentAttempt() {
        XCTAssertEqual(HistoryStallMonitor.evaluate(nowTs: now, lastBankedTs: now - 5 * 86_400,
                                                    lastAttemptTs: now - 7 * 3_600,
                                                    firstEmptyTs: nil, emptyCount: 10), .notConnected)
        XCTAssertEqual(HistoryStallMonitor.evaluate(nowTs: now, lastBankedTs: nil, lastAttemptTs: nil,
                                                    firstEmptyTs: nil, emptyCount: 0), .notConnected)
    }

    func testOkWhenRecentlyBanked() {
        XCTAssertEqual(HistoryStallMonitor.evaluate(nowTs: now, lastBankedTs: now - 600,
                                                    lastAttemptTs: now - 600,
                                                    firstEmptyTs: nil, emptyCount: 0), .ok)
    }

    func testStalledAfter36hOfEmptyOffloads() {
        XCTAssertEqual(HistoryStallMonitor.evaluate(nowTs: now, lastBankedTs: now - 40 * 3_600,
                                                    lastAttemptTs: now - 300,
                                                    firstEmptyTs: now - 39 * 3_600, emptyCount: 50),
                       .stalled(hours: 40))
    }

    func testFewEmptyOffloadsAfterLongGapAreNotAStall() {
        // Phone was away for 3 days; the first two offloads back are empty (flash waking up).
        XCTAssertEqual(HistoryStallMonitor.evaluate(nowTs: now, lastBankedTs: now - 72 * 3_600,
                                                    lastAttemptTs: now - 60,
                                                    firstEmptyTs: now - 600, emptyCount: 2), .ok)
    }

    func testNeverBankedUsesFirstEmptyOffload() {
        XCTAssertEqual(HistoryStallMonitor.evaluate(nowTs: now, lastBankedTs: nil, lastAttemptTs: now - 60,
                                                    firstEmptyTs: now - 10 * 3_600, emptyCount: 20), .ok)
        XCTAssertEqual(HistoryStallMonitor.evaluate(nowTs: now, lastBankedTs: nil, lastAttemptTs: now - 60,
                                                    firstEmptyTs: now - 48 * 3_600, emptyCount: 20),
                       .stalled(hours: 48))
    }
}

final class PlannedSessionAdviceTests: XCTestCase {

    func testIntensityFromWords() {
        XCTAssertEqual(PlannedSessionAdvice.intensity(name: "5x4' VO2max", description: nil,
                                                      durationS: 3_600, load: 60), .hard)
        XCTAssertEqual(PlannedSessionAdvice.intensity(name: "6 x 3 min", description: nil,
                                                      durationS: nil, load: nil), .hard)
        XCTAssertEqual(PlannedSessionAdvice.intensity(name: "Sortie récup", description: nil,
                                                      durationS: 3_600, load: 90), .easy)
        XCTAssertEqual(PlannedSessionAdvice.intensity(name: "Course à pied", description: nil,
                                                      durationS: 45 * 60, load: 30), .easy)
    }

    func testIntensityFromLoad() {
        XCTAssertEqual(PlannedSessionAdvice.intensity(name: "Vélo", description: nil,
                                                      durationS: 3_600, load: 80), .hard)
        XCTAssertEqual(PlannedSessionAdvice.intensity(name: "Vélo", description: nil,
                                                      durationS: 3_600, load: 60), .moderate)
        XCTAssertEqual(PlannedSessionAdvice.intensity(name: "Vélo", description: nil,
                                                      durationS: 2 * 3_600, load: 90), .moderate)
        XCTAssertEqual(PlannedSessionAdvice.intensity(name: "Vélo", description: nil,
                                                      durationS: 3_600, load: 40), .easy)
        XCTAssertEqual(PlannedSessionAdvice.intensity(name: nil, description: nil,
                                                      durationS: nil, load: nil), .moderate)
    }

    func testAdviceBands() {
        XCTAssertNil(PlannedSessionAdvice.advise(charge: nil, intensity: .hard))
        XCTAssertEqual(PlannedSessionAdvice.advise(charge: 80, intensity: .hard)?.level, .go)
        XCTAssertEqual(PlannedSessionAdvice.advise(charge: 50, intensity: .hard)?.level, .adjust)
        XCTAssertEqual(PlannedSessionAdvice.advise(charge: 50, intensity: .moderate)?.level, .go)
        XCTAssertEqual(PlannedSessionAdvice.advise(charge: 20, intensity: .moderate)?.level, .swap)
        XCTAssertEqual(PlannedSessionAdvice.advise(charge: 20, intensity: .easy)?.level, .go)
        XCTAssertEqual(PlannedSessionAdvice.advise(charge: 67, intensity: .hard)?.level, .go)
        XCTAssertEqual(PlannedSessionAdvice.advise(charge: 66.6, intensity: .hard)?.level, .adjust)
        XCTAssertEqual(PlannedSessionAdvice.advise(charge: 33.4, intensity: .hard)?.level, .swap)
    }
}

final class RecoveryFactorsTests: XCTestCase {

    func testDifferenceOfMeansWithMinimumCounts() {
        var days: [RecoveryFactors.Day] = []
        for i in 0..<4 { days.append(.init(day: "y\(i)", nextCharge: 40, flags: ["late": true, "rare": true])) }
        for i in 0..<4 { days.append(.init(day: "n\(i)", nextCharge: 60, flags: ["late": false])) }
        let out = RecoveryFactors.analyse(days)
        XCTAssertEqual(out.count, 1)              // "rare" never has a "no" side
        XCTAssertEqual(out[0].id, "late")
        XCTAssertEqual(out[0].delta, -20, accuracy: 1e-9)
        XCTAssertEqual(out[0].yesCount, 4)
    }

    func testSmallDifferencesAndUnknownChargeAreDropped() {
        var days: [RecoveryFactors.Day] = []
        for i in 0..<3 { days.append(.init(day: "a\(i)", nextCharge: 50, flags: ["x": true, "y": true])) }
        for i in 0..<3 { days.append(.init(day: "b\(i)", nextCharge: 52, flags: ["x": false, "y": false])) }
        days.append(.init(day: "c", nextCharge: nil, flags: ["y": false]))
        XCTAssertTrue(RecoveryFactors.analyse(days).isEmpty)
    }

    func testStrongestFirst() {
        var days: [RecoveryFactors.Day] = []
        for i in 0..<3 { days.append(.init(day: "a\(i)", nextCharge: 70, flags: ["breath": true, "meal": false])) }
        for i in 0..<3 { days.append(.init(day: "b\(i)", nextCharge: 60, flags: ["breath": false, "meal": false])) }
        for i in 0..<3 { days.append(.init(day: "c\(i)", nextCharge: 30, flags: ["breath": false, "meal": true])) }
        let out = RecoveryFactors.analyse(days)
        XCTAssertEqual(out.map(\.id), ["meal", "breath"])
    }
}
