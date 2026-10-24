import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Lead-in cardiac wake for V2 (on by default) (`SleepStagerV2.leadInCardiacWakeEnd`). The quiescent cardiac clamp
/// holds a motionless, elevated-HR epoch out of wake all night, which also credits lying still AWAKE before
/// sleep as sleep, so onset reads early. With the rule on, the clamp is lifted for the pre-sleep lead-in
/// only. These pin: the off path is unchanged, a still awake lead-in moves onset later, the lift stops at
/// sleep onset (a mid-night still elevated-HR stretch keeps the clamp), and the lift is capped at
/// `leadInCardiacWakeMaxMinutes`. Kotlin twin: `LeadInCardiacWakeTest`.
final class LeadInCardiacWakeTests: XCTestCase {

    private let start = 1_749_517_200

    // MARK: - fixtures

    /// Still gravity at 1 Hz for the whole window: the wrist never moves, so every epoch is quiescent.
    private func stillGravity(_ durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1.0) }
    }

    /// Awake-but-still HR (66-72 bpm, stepping every 7 s) over `awakeSpans`, sleep-band HR (52-54) elsewhere.
    private func hr(_ durationS: Int, _ awakeSpans: [Range<Int>]) -> [HRSample] {
        (0..<durationS).map { i in
            let awake = awakeSpans.contains { $0.contains(i) }
            return HRSample(ts: start + i, bpm: awake ? 66 + (i / 7) % 7 : 52 + (i / 60) % 3)
        }
    }

    /// Regular R-R with a small respiratory oscillation, shorter beats while awake.
    private func rr(_ durationS: Int, _ awakeSpans: [Range<Int>]) -> [RRInterval] {
        (0..<durationS).map { i in
            let mean = awakeSpans.contains { $0.contains(i) } ? 880 : 1130
            let rsa = Int((40.0 * sin(2.0 * Double.pi * Double(i) / 4.0)).rounded())
            return RRInterval(ts: start + i, rrMs: mean + rsa)
        }
    }

    private func stage(_ durationS: Int, _ awakeSpans: [Range<Int>], leadIn: Bool) -> [StageSegment] {
        SleepStagerV2.stageSession(start: start, end: start + durationS, grav: stillGravity(durationS),
                                   hr: hr(durationS, awakeSpans), rr: rr(durationS, awakeSpans), resp: [],
                                   leadInCardiacWake: leadIn)
    }

    /// Minutes from the window start to the first non-wake run of at least 5 minutes (the PSG onset rule).
    private func onsetMinutes(_ segs: [StageSegment]) -> Double? {
        var i = 0
        while i < segs.count {
            if segs[i].stage == "wake" { i += 1; continue }
            let runStart = segs[i].start
            var runEnd = segs[i].end
            var j = i + 1
            while j < segs.count, segs[j].stage != "wake" { runEnd = segs[j].end; j += 1 }
            if runEnd - runStart >= 300 { return Double(runStart - start) / 60.0 }
            i = j
        }
        return nil
    }

    private func wakeMinutes(in segs: [StageSegment], from: Int, to: Int) -> Double {
        segs.filter { $0.stage == "wake" }.reduce(0.0) { acc, s in
            acc + Double(max(0, min(s.end, start + to) - max(s.start, start + from)))
        } / 60.0
    }

    // MARK: - the rule in isolation

    private func epoch(_ i: Int) -> SleepStagerV2.Epoch {
        SleepStagerV2.Epoch(start: start + 30 * i, hr: 52, hrVar: 1, hrFlat11: 1, moveFrac: 0, jerkMax: 0.001,
                            respReg: nil, clock: 0, jerkScale: 0.001, minutesSinceOnset: Double(i) * 0.5 + 0.25)
    }

    func testLeadInEndStopsAtTheOpenPassOnset() {
        let feats = (0..<400).map(epoch)
        // 40 awake epochs (20 min) then sustained sleep: everything before the onset is lifted.
        let labels = Array(repeating: "awake", count: 40) + Array(repeating: "light", count: 360)
        XCTAssertEqual(SleepStagerV2.leadInCardiacWakeEnd(feats, openLabels: labels), 40)
    }

    func testLeadInEndIsZeroWhenTheOpenPassNeverSustainsSleepOrSleepsAtOnce() {
        let feats = (0..<100).map(epoch)
        XCTAssertEqual(SleepStagerV2.leadInCardiacWakeEnd(feats, openLabels: Array(repeating: "awake", count: 100)), 0)
        // A non-wake run shorter than the 5-minute rule is not an onset.
        XCTAssertEqual(SleepStagerV2.leadInCardiacWakeEnd(
            feats, openLabels: Array(repeating: "light", count: 9) + Array(repeating: "awake", count: 91)), 0)
        XCTAssertEqual(SleepStagerV2.leadInCardiacWakeEnd(feats, openLabels: Array(repeating: "light", count: 100)), 0)
    }

    func testLeadInEndIsCappedAtThreeHours() {
        let feats = (0..<800).map(epoch)
        // Open-pass onset at epoch 500 (250 min): the lift stops at the last epoch centred within 180 min.
        let labels = Array(repeating: "awake", count: 500) + Array(repeating: "light", count: 300)
        XCTAssertEqual(SleepStagerV2.leadInCardiacWakeEnd(feats, openLabels: labels), 360)
        // A 2-hour lie-in (onset at epoch 240) is lifted whole.
        let twoHours = Array(repeating: "awake", count: 240) + Array(repeating: "light", count: 560)
        XCTAssertEqual(SleepStagerV2.leadInCardiacWakeEnd(feats, openLabels: twoHours), 240)
    }

    // MARK: - end to end through stageSession

    /// The reported shape: 40 minutes lying still awake, then a night of sleep. Off, the clamp credits the
    /// lead-in as sleep; on, onset moves to where the heart rate actually settled.
    func testStillAwakeLeadInMovesOnsetLaterOnlyWhenEnabled() throws {
        let dur = 8 * 60 * 60
        let awake = [0..<(40 * 60)]
        let off = try XCTUnwrap(onsetMinutes(stage(dur, awake, leadIn: false)))
        let on = try XCTUnwrap(onsetMinutes(stage(dur, awake, leadIn: true)))
        XCTAssertLessThan(off, 10.0, "off path should still read the still lead-in as sleep (got \(off) min)")
        XCTAssertTrue((30.0...50.0).contains(on), "on path should place onset near the 40-min settle point (got \(on) min)")
        // The displayed onset reads the same hypnogram through `refinedOnsetTs`.
        let segs = stage(dur, awake, leadIn: true)
        XCTAssertEqual(SleepStagerV2.refinedOnsetTs(segs).map { Double($0 - start) / 60.0 }, on)
    }

    /// A night asleep from the window start stages byte-identically with the flag on, even with a still
    /// elevated-HR stretch mid-night: the lift ends at sleep onset, so the clamp still holds there.
    func testNightAsleepFromTheStartIsUnchangedEvenWithAMidNightElevatedStretch() {
        let dur = 7 * 60 * 60
        let awake = [(4 * 60 * 60)..<(4 * 60 * 60 + 40 * 60)]
        let off = stage(dur, awake, leadIn: false)
        let on = stage(dur, awake, leadIn: true)
        XCTAssertEqual(off, on)
        XCTAssertLessThan(wakeMinutes(in: on, from: 4 * 60 * 60, to: 4 * 60 * 60 + 40 * 60), 5.0)
    }

    /// The second report: two hours lying still awake, then sleep. No sleep bout may be credited inside the
    /// lie-in, so onset lands near the 120-minute settle point.
    func testTwoHourStillLieInIsNotCreditedAsSleep() throws {
        let dur = 9 * 60 * 60
        let on = try XCTUnwrap(onsetMinutes(stage(dur, [0..<(120 * 60)], leadIn: true)))
        XCTAssertTrue((105.0...135.0).contains(on), "onset should sit near the 120-min settle point (got \(on) min)")
    }

    /// A long elevated lead-in: onset never reads earlier than the pre-rule path and never moves past the
    /// truth (150 min) by more than a few minutes; the cap itself is pinned by
    /// `testLeadInEndIsCappedAtThreeHours`.
    func testLiftNeverOvershootsALongElevatedLeadIn() throws {
        let dur = 9 * 60 * 60
        let off = try XCTUnwrap(onsetMinutes(stage(dur, [0..<(150 * 60)], leadIn: false)))
        let on = try XCTUnwrap(onsetMinutes(stage(dur, [0..<(150 * 60)], leadIn: true)))
        XCTAssertGreaterThanOrEqual(on, off)
        XCTAssertLessThanOrEqual(on, 160.0, "onset must not move past the lead-in (got \(on) min)")
    }
}
