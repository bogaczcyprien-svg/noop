import XCTest
@testable import StrandAnalytics

/// Mirrors `PrimarySessionRestingHRTests`' shape — same validity/coverage rules, applied to a flat
/// day-wide bpm array instead of one sleep session's.
final class WholeDayMeanHRTests: XCTestCase {

    func testMeanOfValidSamples() {
        let bpm = Array(repeating: 70.0, count: 40) + Array(repeating: 50.0, count: 10)
        // (40*70 + 10*50) / 50 = 66.0
        XCTAssertEqual(WholeDayMeanHR.mean(bpm: bpm), 66.0)
    }

    func testInvalidSamplesAreExcluded() {
        let bpm = Array(repeating: 60.0, count: 40) + [0, 300, -5, 250]
        XCTAssertEqual(WholeDayMeanHR.mean(bpm: bpm), 60.0)
    }

    func testBelowMinValidSamplesReturnsNil() {
        XCTAssertNil(WholeDayMeanHR.mean(bpm: Array(repeating: 60.0, count: 5)))
    }

    func testAllInvalidReturnsNil() {
        XCTAssertNil(WholeDayMeanHR.mean(bpm: Array(repeating: 0.0, count: 100)))
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(WholeDayMeanHR.mean(bpm: []))
    }

    func testConstantBpmReturnsExactlyThatValue() {
        XCTAssertEqual(WholeDayMeanHR.mean(bpm: Array(repeating: 58.0, count: 300)), 58.0)
    }

    func testAcceptsBucketMeansNotJustRawIntegerReadings() {
        // Repository.hrBuckets hands back fractional bucket means, not raw integer bpm — confirm the
        // Double signature isn't just Int-in-disguise.
        let bpm: [Double] = Array(repeating: 61.5, count: 30) + Array(repeating: 58.25, count: 30)
        XCTAssertEqual(WholeDayMeanHR.mean(bpm: bpm)!, 59.875, accuracy: 1e-9)
    }
}
