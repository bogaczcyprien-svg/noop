import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// FORK-ONLY, not ported to Android. Pins the per-session debrief numbers: zone split, the two 0-5
/// effect estimates, the main benefit, hard efforts, drift and the dropout cap.
final class WorkoutPhysiologyTests: XCTestCase {

    // Personal zones starting at 120 / 132 / 144 / 156 / 168 bpm (zone 4 middle = 162).
    private let zones = HRZones.zones(maxHR: 180, customLowerBounds: [120, 132, 144, 156, 168])

    /// One sample per second for `seconds` seconds at `bpm`, starting at `t`.
    private func block(_ t: inout Int, seconds: Int, bpm: Int) -> [HRSample] {
        defer { t += seconds }
        return (0..<seconds).map { HRSample(ts: t + $0, bpm: bpm) }
    }

    func testSteadyZone2HourIsBaseEndurance() throws {
        var t = 1_000
        let hr = block(&t, seconds: 3600, bpm: 138)   // zone 2
        let r = try XCTUnwrap(WorkoutPhysiology.analyse(hr: hr, zoneSet: zones))
        XCTAssertEqual(r.zoneMinutes[2], 60.0, accuracy: 0.01)
        XCTAssertEqual(r.edwardsLoad, 120.0, accuracy: 0.01)
        XCTAssertEqual(r.aerobicEffect, 3.3)
        XCTAssertEqual(r.anaerobicEffect, 0)
        XCTAssertEqual(r.benefit, .base)
        XCTAssertEqual(r.hardEfforts, 0)
        XCTAssertEqual(r.anaerobicSharePct, 0)
        XCTAssertEqual(r.peak60sHR ?? 0, 138, accuracy: 0.01)
        XCTAssertEqual(r.driftPct ?? 99, 0, accuracy: 0.01)
    }

    func testIntervalsAreAnaerobic() throws {
        var t = 1_000
        var hr = block(&t, seconds: 600, bpm: 138)            // 10 min warm-up, zone 2
        for _ in 0..<6 {
            hr += block(&t, seconds: 180, bpm: 174)           // 3 min in zone 5
            hr += block(&t, seconds: 120, bpm: 132)           // 2 min in zone 2
        }
        let r = try XCTUnwrap(WorkoutPhysiology.analyse(hr: hr, zoneSet: zones))
        XCTAssertEqual(r.zoneMinutes[5], 18.0, accuracy: 0.01)
        XCTAssertEqual(r.zoneMinutes[2], 22.0, accuracy: 0.01)
        XCTAssertEqual(r.hardEfforts, 6)
        XCTAssertEqual(r.anaerobicEffect, 4.4)   // 18 anaerobic min -> 4.1, +0.3 for 6 efforts
        XCTAssertEqual(r.aerobicEffect, 3.5)     // load 18x5 + 22x2 = 134
        XCTAssertEqual(r.benefit, .anaerobic)
        XCTAssertEqual(r.anaerobicSharePct, 45.0, accuracy: 0.01)
        XCTAssertNil(r.driftPct, "an interval session is not a steady one")
    }

    func testRisingHeartRateShowsDrift() throws {
        let hr = (0..<3600).map { HRSample(ts: 1_000 + $0, bpm: 130 + $0 * 20 / 3600) }
        let r = try XCTUnwrap(WorkoutPhysiology.analyse(hr: hr, zoneSet: zones))
        XCTAssertGreaterThan(r.driftPct ?? 0, 3)
    }

    func testShortSessionHasNoDrift() throws {
        var t = 1_000
        let hr = block(&t, seconds: 20 * 60, bpm: 138)
        XCTAssertNil(try XCTUnwrap(WorkoutPhysiology.analyse(hr: hr, zoneSet: zones)).driftPct)
    }

    func testDropoutIsNotCreditedAsEffort() throws {
        // Ten minutes, a ten-minute hole, ten more minutes: the hole carries one median gap, not 600 s.
        var t = 0
        var hr = block(&t, seconds: 600, bpm: 138)
        t += 600
        hr += block(&t, seconds: 600, bpm: 138)
        let r = try XCTUnwrap(WorkoutPhysiology.analyse(hr: hr, zoneSet: zones))
        XCTAssertEqual(r.totalMinutes, 20.0, accuracy: 0.05)
    }

    func testDegenerateInputIsNil() {
        XCTAssertNil(WorkoutPhysiology.analyse(hr: [], zoneSet: zones))
        XCTAssertNil(WorkoutPhysiology.analyse(hr: [HRSample(ts: 0, bpm: 10)], zoneSet: zones))
    }

    func testEffectCurvesAndLabels() {
        XCTAssertEqual(WorkoutPhysiology.aerobicEffect(edwardsLoad: 0), 0)
        XCTAssertEqual(WorkoutPhysiology.aerobicEffect(edwardsLoad: 50), 2)
        XCTAssertEqual(WorkoutPhysiology.aerobicEffect(edwardsLoad: 1_000), 5)
        XCTAssertEqual(WorkoutPhysiology.anaerobicEffect(anaerobicMinutes: 6, hardEfforts: 0), 2.6)
        XCTAssertEqual(WorkoutPhysiology.effectLabelFR(0.5), "Aucun effet")
        XCTAssertEqual(WorkoutPhysiology.effectLabelFR(3.3), "Améliore")
        XCTAssertEqual(WorkoutPhysiology.effectLabelFR(5), "Surcharge")
    }

    func testUsesThePersonalZones() throws {
        // 130 bpm is zone 1 with these boundaries; with the default %HRmax bands of a 180 max it is zone 3.
        var t = 0
        let hr = block(&t, seconds: 600, bpm: 130)
        let mine = try XCTUnwrap(WorkoutPhysiology.analyse(hr: hr, zoneSet: zones))
        XCTAssertEqual(mine.zoneMinutes[1], 10.0, accuracy: 0.01)
        let defaults = try XCTUnwrap(WorkoutPhysiology.analyse(hr: hr, zoneSet: HRZones.zones(maxHR: 180)))
        XCTAssertEqual(defaults.zoneMinutes[3], 10.0, accuracy: 0.01)
        XCTAssertEqual(mine.zoneLowerBoundsBPM, [120, 132, 144, 156, 168])
    }
}
