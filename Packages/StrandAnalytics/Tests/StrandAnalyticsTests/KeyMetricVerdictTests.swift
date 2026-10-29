import XCTest
@testable import StrandAnalytics

final class KeyMetricVerdictTests: XCTestCase {

    /// 14 days alternating 58 and 62: mean 60, spread 2.
    private let history = (0..<14).map { $0 % 2 == 0 ? 58.0 : 62.0 }

    func testNoUsualBeforeSevenDays() {
        XCTAssertNil(KeyMetricVerdict.usual([60, 61, 59, 60, 62, 58]))
        XCTAssertNil(KeyMetricVerdict.relative(value: 60, history: Array(history.prefix(6)),
                                               rule: .higherIsBetter, minSpread: 1))
        XCTAssertEqual(KeyMetricVerdict.usual(history), 60)
    }

    func testHigherIsBetter() throws {
        let up = try XCTUnwrap(KeyMetricVerdict.relative(value: 63, history: history, rule: .higherIsBetter, minSpread: 1))
        XCTAssertEqual(up.tone, .good)
        XCTAssertEqual(up.direction, .above)
        XCTAssertEqual(up.usual, 60)
        let same = try XCTUnwrap(KeyMetricVerdict.relative(value: 60.5, history: history, rule: .higherIsBetter, minSpread: 1))
        XCTAssertEqual(same.tone, .normal)
        XCTAssertEqual(same.direction, .inline)
        // 1 spread below: watch; 2 spreads below: well below, off.
        XCTAssertEqual(KeyMetricVerdict.relative(value: 58, history: history, rule: .higherIsBetter, minSpread: 1)?.tone, .watch)
        let low = try XCTUnwrap(KeyMetricVerdict.relative(value: 56, history: history, rule: .higherIsBetter, minSpread: 1))
        XCTAssertEqual(low.tone, .off)
        XCTAssertTrue(low.strong)
    }

    func testLowerIsBetterMirrors() {
        XCTAssertEqual(KeyMetricVerdict.relative(value: 57, history: history, rule: .lowerIsBetter, minSpread: 1)?.tone, .good)
        XCTAssertEqual(KeyMetricVerdict.relative(value: 62, history: history, rule: .lowerIsBetter, minSpread: 1)?.tone, .watch)
        XCTAssertEqual(KeyMetricVerdict.relative(value: 64, history: history, rule: .lowerIsBetter, minSpread: 1)?.tone, .off)
    }

    func testSteadyLowIsBadAndNeither() {
        XCTAssertEqual(KeyMetricVerdict.relative(value: 62, history: history, rule: .steadyIsBetter, minSpread: 1)?.tone, .watch)
        XCTAssertEqual(KeyMetricVerdict.relative(value: 57, history: history, rule: .steadyIsBetter, minSpread: 1)?.tone, .off)
        XCTAssertEqual(KeyMetricVerdict.relative(value: 64, history: history, rule: .lowIsBad, minSpread: 1)?.tone, .normal)
        XCTAssertEqual(KeyMetricVerdict.relative(value: 57, history: history, rule: .lowIsBad, minSpread: 1)?.tone, .off)
        let more = KeyMetricVerdict.relative(value: 66, history: history, rule: .neither, minSpread: 1)
        XCTAssertEqual(more?.tone, .neutral)
        XCTAssertEqual(more?.direction, .above)
    }

    func testMinSpreadKeepsASteadyHistoryFromOverreacting() {
        let flat = Array(repeating: 14.0, count: 10)
        // Spread 0 floored to 0.4: +0.1 stays normal, +0.3 is above but not well above.
        XCTAssertEqual(KeyMetricVerdict.relative(value: 14.1, history: flat, rule: .steadyIsBetter, minSpread: 0.4)?.tone, .normal)
        let r = KeyMetricVerdict.relative(value: 14.3, history: flat, rule: .steadyIsBetter, minSpread: 0.4)
        XCTAssertEqual(r?.tone, .watch)
        XCTAssertEqual(r?.strong, false)
    }

    func testZones() {
        XCTAssertEqual(KeyMetricVerdict.recovery(72)?.tone, .good)
        XCTAssertEqual(KeyMetricVerdict.recovery(67)?.tone, .good)
        XCTAssertEqual(KeyMetricVerdict.recovery(50)?.tone, .watch)
        XCTAssertEqual(KeyMetricVerdict.recovery(33)?.tone, .off)
        XCTAssertEqual(KeyMetricVerdict.rest(86)?.tone, .good)
        XCTAssertEqual(KeyMetricVerdict.rest(75)?.tone, .watch)
        XCTAssertEqual(KeyMetricVerdict.rest(60)?.tone, .off)
        XCTAssertNil(KeyMetricVerdict.recovery(nil))
    }
}
