import XCTest
@testable import StrandAnalytics

/// FORK-ONLY, not ported to Android. The Breathing tab's suggestion of the day.
final class BreathingDailyPickTests: XCTestCase {
    private typealias C = BreathingScienceCatalog

    func testEveningIsSleepBreathing() {
        XCTAssertEqual(BreathingDailyPick.pick(charge: 90, hour: 22, hasResonancePace: true).exerciseId, C.sleepId)
        XCTAssertEqual(BreathingDailyPick.pick(charge: nil, hour: 2, hasResonancePace: false).exerciseId, C.sleepId)
    }

    func testNoChargeIsCyclicSigh() {
        XCTAssertEqual(BreathingDailyPick.pick(charge: nil, hour: 10, hasResonancePace: true).exerciseId, C.cyclicSighId)
    }

    func testMissingResonancePaceIsFoundOnAGoodDay() {
        XCTAssertEqual(BreathingDailyPick.pick(charge: 70, hour: 10, hasResonancePace: false).exerciseId, C.resonanceTestId)
        // ...but not on a low day.
        XCTAssertEqual(BreathingDailyPick.pick(charge: 20, hour: 10, hasResonancePace: false).exerciseId, C.coherenceId)
    }

    func testChargeBands() {
        XCTAssertEqual(BreathingDailyPick.pick(charge: 20, hour: 10, hasResonancePace: true).exerciseId, C.coherenceId)
        XCTAssertEqual(BreathingDailyPick.pick(charge: 50, hour: 10, hasResonancePace: true).exerciseId, C.resonanceId)
        XCTAssertEqual(BreathingDailyPick.pick(charge: 80, hour: 9, hasResonancePace: true).exerciseId, C.breathHoldsId)
        XCTAssertEqual(BreathingDailyPick.pick(charge: 80, hour: 15, hasResonancePace: true).exerciseId, C.co2Id)
    }

    func testEveryPickIsInTheCatalogue() {
        for charge in [nil, 10.0, 50.0, 90.0] as [Double?] {
            for hour in [3, 9, 15, 22] {
                for pace in [true, false] {
                    let id = BreathingDailyPick.pick(charge: charge, hour: hour, hasResonancePace: pace).exerciseId
                    XCTAssertNotNil(C.exercise(id), id)
                }
            }
        }
    }
}
