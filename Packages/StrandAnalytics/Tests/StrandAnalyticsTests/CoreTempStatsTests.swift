import XCTest
@testable import StrandAnalytics

final class CoreTempStatsTests: XCTestCase {

    func testAverageAndMaxSkipNullsAndImplausibleValues() throws {
        let stream: [Double?] = [nil, 37.0, 37.2, 0, 37.4, nil, 37.6, 37.8, 38.0, 38.2, 38.4, 38.6, 60.0]
        let s = try XCTUnwrap(CoreTempStats.summary(stream))
        XCTAssertEqual(s.samples, 9)
        XCTAssertEqual(s.avgC, 37.8, accuracy: 1e-9)
        XCTAssertEqual(s.maxC, 38.6, accuracy: 1e-9)
    }

    func testTooFewValidSamplesGiveNothing() {
        XCTAssertNil(CoreTempStats.summary([]))
        XCTAssertNil(CoreTempStats.summary(Array(repeating: nil, count: 50)))
        XCTAssertNil(CoreTempStats.summary(Array(repeating: 37.5, count: 9)))
    }
}
