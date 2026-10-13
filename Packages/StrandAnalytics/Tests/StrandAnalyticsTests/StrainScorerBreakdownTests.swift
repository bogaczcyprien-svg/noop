import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// FORK-ONLY, not ported to Android. `StrainScorer.breakdown` is a diagnostic read of the SAME
/// computation `strain(...)` performs — these tests pin that the two never disagree, plus the
/// zone/peak fields a "what shaped this Effort" screen needs.
final class StrainScorerBreakdownTests: XCTestCase {

    private func hr(_ bpm: Int, _ n: Int, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testBreakdownStrainMatchesStrainForIdenticalInputs() {
        let samples = hr(185, 600)
        let s = StrainScorer.strain(samples, maxHR: 190, restingHR: 60)!
        let b = StrainScorer.breakdown(samples, maxHR: 190, restingHR: 60)!
        XCTAssertEqual(b.strain, s, accuracy: 1e-9)
        XCTAssertEqual(b.hrMaxUsed, 190)
        XCTAssertEqual(b.restingHRUsed, 60)
    }

    func testBreakdownReturnsNilInLockstepWithStrain() {
        // Below minReadings/minSparseReadings -> both refuse.
        let tooFew = hr(150, 5)
        XCTAssertNil(StrainScorer.strain(tooFew, maxHR: 190, restingHR: 60))
        XCTAssertNil(StrainScorer.breakdown(tooFew, maxHR: 190, restingHR: 60))
        // Degenerate reserve (maxHR <= restingHR) -> both refuse even with plenty of samples.
        let plenty = hr(150, 1000)
        XCTAssertNil(StrainScorer.strain(plenty, maxHR: 60, restingHR: 60))
        XCTAssertNil(StrainScorer.breakdown(plenty, maxHR: 60, restingHR: 60))
    }

    /// The exact scenario reported against a live device: resting 44, max 195 (a real override),
    /// HR never exceeding ~83 bpm. Zone 1's floor is 60% HRR = 44 + 0.6*(195-44) = 134.6 bpm, so
    /// NOTHING in this stream should reach zone 1 — the day must score (near) zero.
    func testQuietDayWellBelowZoneOneScoresNearZero() {
        // A plausible quiet-morning trace: mostly 44-55, a brief errand bump to 83, 40 minutes @ 1 Hz.
        var samples: [HRSample] = []
        var t = 0
        for bpm in [46, 50, 55, 50, 83, 70, 55, 48] {
            samples.append(contentsOf: hr(bpm, 300, start: t))   // 5 min per leg
            t += 300
        }
        let b = StrainScorer.breakdown(samples, maxHR: 195, restingHR: 44)!
        XCTAssertEqual(b.zoneMinutes[1...5].reduce(0, +), 0.0,
                       "no sample in this trace clears zone 1's 134.6 bpm floor")
        XCTAssertEqual(b.trimp, 0.0, accuracy: 1e-9)
        XCTAssertEqual(b.strain, 0.0, accuracy: 1e-9)
        XCTAssertEqual(b.peakBpm, 83.0)
    }

    func testZoneMinutesSumsToTotalDuration() {
        let samples = hr(185, 600) + hr(50, 600)   // 1200 1Hz samples = 20 minutes
        let b = StrainScorer.breakdown(samples, maxHR: 190, restingHR: 60)!
        XCTAssertEqual(b.zoneMinutes.reduce(0, +), 20.0, accuracy: 1e-6)
        XCTAssertEqual(b.zoneMinutes[5], 10.0, accuracy: 1e-6)   // the 185bpm leg: zone 5
        XCTAssertEqual(b.zoneMinutes[0], 10.0, accuracy: 1e-6)   // the 50bpm leg: below zone 1 (== rest)
    }

    func testPeakAndSustainedPeakDistinguishASingleSampleSpike() {
        // 59 minutes resting at 50 bpm, one isolated 1-second spike to 180 (a PPG/motion artefact).
        var samples = hr(50, 59 * 60)
        samples.append(HRSample(ts: samples.count, bpm: 180))
        let b = StrainScorer.breakdown(samples, maxHR: 190, restingHR: 60)!
        XCTAssertEqual(b.peakBpm, 180.0)
        // No run of `sustainedPeakSamples` consecutive readings holds anywhere near 180.
        XCTAssertNotEqual(b.sustainedPeakBpm, 180.0)
    }
}
