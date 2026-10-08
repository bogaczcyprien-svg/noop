import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class DaytimeStressTests: XCTestCase {

    /// Fill one local hour-of-day with `n` 1 Hz HR samples at `bpm` (UTC, tz offset 0).
    private func hourHR(_ hour: Int, bpm: Int, n: Int = DaytimeStress.minHourHRSamples) -> [HRSample] {
        let base = hour * 3_600
        return (0..<n).map { HRSample(ts: base + $0, bpm: bpm) }
    }

    /// Continuous HR samples spanning `durationSeconds` from `startSeconds`, one every `stepSeconds`
    /// — unlike `hourHR` (which only fills the first few seconds of an hour), this actually covers
    /// real wall-clock duration, needed to build fixtures spanning many consecutive `bucketSeconds`
    /// windows (e.g. `sustainedWindows`' 36 x 5-min test below).
    private func continuousHR(fromSeconds start: Int, durationSeconds: Int, bpm: Int, stepSeconds: Int = 50) -> [HRSample] {
        stride(from: 0, to: durationSeconds, by: stepSeconds).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testTheSlidingReadIsOptIn() {
        let (hr, rr) = wornMorning()
        // The Stress screen reads `hours` and draws its own timeline, so it must not pay for a second
        // pass of bucketing and an RMSSD per extra window. Default off means `timeline` IS `hours`.
        let plain = DaytimeStress.analyze(hr: hr, rr: rr)
        XCTAssertEqual(plain.timeline, plain.hours)
        XCTAssertGreaterThan(
            DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true).timeline.count,
            plain.hours.count)
    }

    // MARK: - the half-step display timeline

    /// A plain worn morning: several waking hours of steady HR with a little R-R jitter.
    private func wornMorning() -> ([HRSample], [RRInterval]) {
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in 7...11 {
            hr += hourHR(h, bpm: 60 + (h - 7) * 4)
            rr += hourRRVariable(h, rrMs: 900, jitter: 20)
        }
        return (hr, rr)
    }

    func testTimelineKeepsEveryHourlyPointExactlyAsScored() {
        let (hr, rr) = wornMorning()
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        // The sliding read must not restate the hours it slides between: a point on the hour has to
        // carry the same level it carried before this existed, or the curve would disagree with every
        // other surface that reads `hours`.
        let byStart = Dictionary(uniqueKeysWithValues: res.timeline.map { ($0.startTs, $0) })
        XCTAssertFalse(res.hours.isEmpty)
        for h in res.hours {
            XCTAssertEqual(byStart[h.startTs]?.level, h.level, "hour \(h.startTs) restated")
            XCTAssertEqual(byStart[h.startTs]?.maskedForActivity, h.maskedForActivity)
        }
    }

    func testTimelineAddsTheStraddlingMidpointsAndNothingElse() {
        let (hr, rr) = wornMorning()
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        XCTAssertGreaterThan(res.timeline.count, res.hours.count)
        let hourly = Set(res.hours.map(\.startTs))
        let extras = res.timeline.filter { !hourly.contains($0.startTs) }
        XCTAssertFalse(extras.isEmpty)
        // FORK CHANGE: every added point now sits at ONE OF SEVERAL phases inside the window — a
        // multiple of `timelineStepSeconds`, not just `timelineStepSeconds` itself (see the
        // `analyzeUncached` `timeline` step's own doc comment for why one straddling copy stopped
        // being enough once `timelineStepSeconds` became a fifth of `bucketSeconds` instead of half).
        // A point anywhere else would mean the grid, not a phase, had moved.
        for e in extras {
            let offset = ((e.startTs % DaytimeStress.bucketSeconds) + DaytimeStress.bucketSeconds)
                % DaytimeStress.bucketSeconds
            XCTAssertEqual(offset % DaytimeStress.timelineStepSeconds, 0)
            XCTAssertGreaterThan(offset, 0)
            XCTAssertLessThan(offset, DaytimeStress.bucketSeconds)
        }
        XCTAssertEqual(res.timeline.map(\.startTs), res.timeline.map(\.startTs).sorted())
    }

    func testHourCountingIgnoresTheSlidingRead() {
        let (hr, rr) = wornMorning()
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        // Overlapping windows would count the same minute twice, so the minute total stays on the
        // non-overlapping hours. This is the assertion that fails first if someone later points
        // `highStressMinutes` at the denser series.
        let highHours = res.hours.filter { ($0.level ?? 0) >= DaytimeStress.highBandFloor }.count
        XCTAssertEqual(res.highStressMinutes, highHours * (DaytimeStress.bucketSeconds / 60))
        XCTAssertEqual(res.activityMaskedHours, res.hours.filter(\.maskedForActivity).count)
    }

    func testASteadyDayScoresItsMidpointsLikeItsHours() {
        // Same HR every hour: with one shared reference the midpoints must land on the same level as
        // the hours they straddle. If the sliding pass ever derived its OWN calm reference, this is
        // where it would show up, as a curve that zigzags between two scales rather than tracking one.
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in 8...12 { hr += hourHR(h, bpm: 66); rr += hourRRVariable(h, rrMs: 900, jitter: 20) }
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        let levels = Set(res.timeline.compactMap { $0.level.map { String(format: "%.6f", $0) } })
        XCTAssertLessThanOrEqual(levels.count, 1, "a flat day should not zigzag, got \(levels)")
    }

    func testTimelineMatchesTheKotlinTwinValueForValue() {
        // `res.hours` is STILL the Kotlin-twin oracle: this fixture's samples all land in the first
        // few seconds of each clock hour, so the on-the-grid (phase 0) bucket starts at exactly that
        // hour on both platforms regardless of bucket WIDTH, and the scoring formula itself never
        // diverged. The Kotlin `DaytimeStressTest` asserts this same literal for this same scenario.
        let (hr, rr) = wornMorning()
        let res = DaytimeStress.analyze(hr: hr, rr: rr, includeTimeline: true)
        func render(_ points: [DaytimeStress.HourPoint]) -> String {
            points.map { "\($0.startTs):" + ($0.level.map { String(format: "%.6f", $0) } ?? "nil") }
                .joined(separator: " ")
        }
        XCTAssertEqual(render(res.hours),
                       "25200:0.990715 28800:1.500000 32400:2.009285 36000:2.413289 39600:2.678875")

        // FORK DIVERGENCE, not ported to Android: `bucketSeconds`/`timelineStepSeconds` no longer
        // match the Kotlin twin's 3600/1800 pair (see those constants' own doc comments), so
        // `timeline`'s exact shape stops being a cross-platform oracle here — only `res.hours` above
        // still is. This fixture's samples are tightly clustered at the start of each hour, so EVERY
        // phase (0, 60, 120, 180, 240) still catches them: each hour contributes exactly
        // `bucketSeconds / timelineStepSeconds` timeline points, all sharing that hour's own level
        // (same underlying samples, same reference — never a second, drifting scale).
        let phasesPerHour = DaytimeStress.bucketSeconds / DaytimeStress.timelineStepSeconds
        XCTAssertEqual(res.timeline.count, res.hours.count * phasesPerHour)
        for h in res.hours {
            let siblings = res.timeline.filter { abs($0.startTs - h.startTs) < DaytimeStress.bucketSeconds }
            XCTAssertEqual(siblings.count, phasesPerHour)
            for s in siblings {
                XCTAssertEqual(s.level, h.level, "a straddling point must share its parent hour's level")
            }
        }

        // FORK DIVERGENCE, not ported to Android: `sustainedWindows` (36 x 5-min windows = 3 real
        // hours) replaced the Kotlin twin's `sustainedHours` (3 x 1-hour windows). This fixture's 3
        // trailing high points no longer clear that bar — it would need 36 CONSECUTIVE high windows,
        // not 3 (see `testSustainedHighFlagsAfterSustainedWindowsOfHighReadings` for that scenario
        // built out properly). `sustainedRun` itself is unaffected: it is still exactly how many
        // trailing scored points are HIGH, independent of the bar `sustainedHigh` checks it against.
        XCTAssertEqual(res.highStressMinutes, 3 * (DaytimeStress.bucketSeconds / 60))
        XCTAssertFalse(res.sustainedHigh)
        XCTAssertEqual(res.sustainedRun, 3)
        XCTAssertEqual(res.peak?.startTs, 39600)
    }

    func testEmptyWhenNoHR() {
        XCTAssertEqual(DaytimeStress.analyze(hr: [], rr: []), .empty)
    }

    func testHourBelowGateIsUnscored() {
        // One waking hour with too few HR samples → present but unscored (honest gap).
        let hr = hourHR(9, bpm: 70, n: DaytimeStress.minHourHRSamples - 1)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertTrue(r.scored.isEmpty, "an under-gate hour must not be scored")
    }

    func testScoresMapOntoZeroToThree() {
        // Three calm hours + one tense hour (high HR). All scored values stay within 0…3.
        var hr: [HRSample] = []
        hr += hourHR(8, bpm: 62)
        hr += hourHR(9, bpm: 60)
        hr += hourHR(10, bpm: 61)
        hr += hourHR(11, bpm: 95)   // the spike
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.scored.isEmpty)
        for p in r.scored {
            let lvl = p.level!
            XCTAssertGreaterThanOrEqual(lvl, 0)
            XCTAssertLessThanOrEqual(lvl, 3)
        }
        // The high-HR hour must be the day's peak and read above the calm hours.
        XCTAssertEqual(r.peak?.hour, 11)
        let calm = r.scored.first { $0.hour == 9 }!.level!
        let tense = r.scored.first { $0.hour == 11 }!.level!
        XCTAssertGreaterThan(tense, calm)
    }

    /// FORK CHANGE (#WHOOP-parity, explicit request — "je veux le stress comme WHOOP, le graphique
    /// aussi"): `isWakingHour` used to hard-cut at 06:00–22:00, which left a real gap on the chart for
    /// anyone awake outside that window (a late bedtime, an early riser) — not because they were
    /// asleep, purely because of the clock. The window is now the full day; only a REAL sleep span
    /// (via `maskedForSleep`, tested elsewhere) excludes an hour. Renamed from
    /// `testNonWakingHoursAreExcluded`, which tested the behaviour this replaces.
    func testEveryHourIsOnTheTimelineUnlessItOverlapsRealSleep() {
        // A 3 am hour with no sleep span supplied is awake-by-default and now scored like any other.
        let hr = hourHR(3, bpm: 80) + hourHR(9, bpm: 60)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertTrue(r.hours.contains { $0.hour == 3 }, "a 3 am hour with no sleep span is awake, not excluded by clock")
        XCTAssertTrue(r.hours.contains { $0.hour == 9 })
    }

    func testSustainedHighFlagsAfterSustainedWindowsOfHighReadings() {
        // FORK CHANGE: `sustainedWindows` (36 x 5-min windows = 3 real hours, see that constant's doc
        // comment) replaced `sustainedHours` (3 x 1-hour windows) — a trailing run now needs 36
        // CONSECUTIVE scored 5-minute windows at HIGH, not 3 hourly ones. A long calm stretch (so the
        // calm reference anchors low and isn't swamped by the tense run's own sample count) followed
        // by a CONTINUOUS tense stretch spanning exactly `sustainedWindows` windows.
        let calmDuration = 12 * 3_600
        let tenseDuration = DaytimeStress.sustainedWindows * DaytimeStress.bucketSeconds
        var hr = continuousHR(fromSeconds: 0, durationSeconds: calmDuration, bpm: 58)
        hr += continuousHR(fromSeconds: 13 * 3_600, durationSeconds: tenseDuration, bpm: 130)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertTrue(r.sustainedHigh, "sustainedWindows consecutive HIGH 5-minute windows should flag sustained stress")
        XCTAssertGreaterThanOrEqual(r.sustainedRun, DaytimeStress.sustainedWindows)
    }

    func testSustainedHighNeedsEveryWindowInTheRunNotJustSomeOfThem() {
        // One window short of `sustainedWindows` consecutive HIGH windows must not flag — this is the
        // boundary the `>=` in `testSustainedHighFlagsAfterSustainedWindowsOfHighReadings` doesn't
        // exercise on its own.
        let calmDuration = 12 * 3_600
        let tenseDuration = (DaytimeStress.sustainedWindows - 1) * DaytimeStress.bucketSeconds
        var hr = continuousHR(fromSeconds: 0, durationSeconds: calmDuration, bpm: 58)
        hr += continuousHR(fromSeconds: 13 * 3_600, durationSeconds: tenseDuration, bpm: 130)
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.sustainedHigh, "one window short of sustainedWindows must not flag sustained stress")
    }

    func testFlatDayDoesNotFlagSustained() {
        // Every hour at the same HR → no hour is meaningfully elevated, no flag.
        var hr: [HRSample] = []
        for h in 8...16 { hr += hourHR(h, bpm: 64) }
        let r = DaytimeStress.analyze(hr: hr, rr: [])
        XCTAssertFalse(r.sustainedHigh)
        // A flat day sits around the baseline (≈1.5), not pinned high.
        if let mean = r.dayMean { XCTAssertLessThan(mean, DaytimeStress.highBandFloor) }
    }

    func testSleepHoursInTheWindowDoNotShiftTheWakingTimeline() {
        // Regression: the calm reference is built from the WAKING hours that are actually
        // scored, not the whole 24 h. The analysis window always starts at local midnight, so
        // the current day routinely carries several hours of sleep — the calmest, lowest-HR
        // stretch of the day. If those night hours leak into the reference they drag the "calm"
        // anchor far below every waking hour, inflating an ordinary calm day into sustained
        // high stress (tripping the passive Breathe nudge). So adding calm sleep hours to the
        // input must NOT change the waking timeline.
        //
        // FORK CHANGE: `isWakingHour` now spans the full day (see `wakingStartHour`'s doc
        // comment — #WHOOP-parity, "je veux vraiment le stress comme WHOOP"), so hours 0-5 are
        // no longer excluded by clock alone. The fixture must mark them as sleep EXPLICITLY via
        // `sleepSpans`, the real mechanism `overlapsSleep` reads, instead of relying on the old
        // clock cutoff as an incidental stand-in for "asleep".
        let waking: [HRSample] = zip(6...17, [62, 64, 63, 65, 64, 63, 62, 64, 66, 63, 64, 65])
            .flatMap { hourHR($0.0, bpm: $0.1) }
        let sleep: [HRSample] = zip(0...5, [50, 51, 52, 51, 50, 53])
            .flatMap { hourHR($0.0, bpm: $0.1) }
        let sleepSpans: [(start: Int, end: Int)] = [(start: 0, end: 6 * 3_600)]

        let wakingOnly = DaytimeStress.analyze(hr: waking, rr: [])
        let withSleep = DaytimeStress.analyze(hr: sleep + waking, rr: [], sleepSpans: sleepSpans)

        XCTAssertEqual(withSleep.sustainedHigh, wakingOnly.sustainedHigh,
            "sleep hours sharing the window must not change the sustained-high verdict")
        for h in 6...17 {
            guard let withLvl = withSleep.scored.first(where: { $0.hour == h })?.level,
                  let withoutLvl = wakingOnly.scored.first(where: { $0.hour == h })?.level else {
                XCTFail("waking hour \(h) should be scored in both runs"); continue
            }
            XCTAssertEqual(withLvl, withoutLvl, accuracy: 1e-9,
                "the night's sleep hours leaked into the daytime reference and shifted waking hour \(h)")
        }
        // The plain sanity check the bug violated: an ordinary calm day is not "sustained high".
        XCTAssertFalse(withSleep.sustainedHigh,
            "a calm desk day must not read as sustained high stress")
    }

    func testTimezoneOffsetShiftsWakingWindow() {
        // ts at UTC hour 4 with a +3 h offset lands at local hour 7, not UTC hour 4 — the tzOffset
        // arithmetic itself, independent of the (now full-day, see `wakingStartHour`'s doc comment)
        // waking window, which no longer excludes anything by clock.
        let hr = hourHR(4, bpm: 60)
        let r = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 3 * 3_600)
        XCTAssertTrue(r.hours.contains { $0.hour == 7 })
        XCTAssertFalse(r.hours.contains { $0.hour == 4 }, "the hour must be reported at its LOCAL hour, not the raw UTC one")
    }

    func testRMSSDLowersStressDirectionMatchesDailyScore() {
        // Same HR across hours; the hour with the LOWEST HRV (RMSSD) should read more
        // stressed — the same directionality as the daily score (HRV down = stress).
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in [8, 9, 10, 11] { hr += hourHR(h, bpm: 65) }
        // High-variability (relaxed) hours vs one low-variability (tense) hour.
        rr += hourRRVariable(8, rrMs: 900, jitter: 40)
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)
        rr += hourRRVariable(10, rrMs: 900, jitter: 40)
        rr += hourRRVariable(11, rrMs: 900, jitter: 2)   // suppressed HRV
        let r = DaytimeStress.analyze(hr: hr, rr: rr)
        let relaxed = r.scored.first { $0.hour == 9 }!.level!
        let tense = r.scored.first { $0.hour == 11 }!.level!
        XCTAssertGreaterThan(tense, relaxed)
    }

    /// R-R for one hour with a controllable beat-to-beat jitter (drives RMSSD). FORK FIX: stepped at
    /// 50s, which only put 6 of its 60 samples inside the matching 5-minute `bucketSeconds` bucket
    /// (the rest landed in later buckets this fixture's HR never touches, so they were silently
    /// ignored) — below `minDaytimeBucketRRBeats` (8), so RMSSD came back nil and tests relying on it
    /// lost their signal. 20s puts 15 samples inside the first 300s, comfortably clearing the gate.
    private func hourRRVariable(_ hour: Int, rrMs: Int, jitter: Int, n: Int = 60) -> [RRInterval] {
        let base = hour * 3_600
        return (0..<n).map { RRInterval(ts: base + $0 * 20, rrMs: rrMs + ($0 % 2 == 0 ? jitter : -jitter)) }
    }

    // MARK: - Motion gate

    /// Gravity for one local hour. `activeFraction` of the records step far enough between
    /// consecutive samples to clear `DaytimeStress.stressMotionThreshold` (0.45 g L2); the rest hold
    /// still. FORK FIX: used to bunch all its active records at the START of the hour, which only
    /// worked while gravity was aggregated over the whole hour in one go — now that it is bucketed
    /// into 5-minute `bucketSeconds` windows, bunching concentrated a 10%-active hour into one
    /// ~100%-active bucket followed by several untouched ones instead of ~10% active throughout, which
    /// is what `activeFraction` is meant to simulate. Active indices are now spread EVENLY across the
    /// hour instead. An isolated active sample (its predecessor not active) always steps up from the
    /// still 0.0 background, which is enough contrast on its own; a RUN of active samples (reached at
    /// `activeFraction` 1.0, where every index is active) still alternates relative to its own
    /// predecessor, exactly as before, so a long run keeps stepping instead of going flat at a
    /// constant value with zero delta between samples.
    private func hourGravity(_ hour: Int, activeFraction: Double, n: Int = 120) -> [GravitySample] {
        let base = hour * 3_600
        let activeCount = Int((Double(n) * activeFraction).rounded())
        let activeIndices: Set<Int> = activeCount > 0
            ? Set((0..<activeCount).map { k in Int((Double(k) * Double(n) / Double(activeCount)).rounded(.down)) })
            : []
        var lastWasActive = false
        var lastX = 0.0
        return (0..<n).map { i in
            var x = 0.0
            if activeIndices.contains(i) {
                // 0.5 g of step per axis-pair clears the 0.45 g stress-motion bar.
                x = lastWasActive ? (lastX == 0.5 ? 0.0 : 0.5) : 0.5
                lastWasActive = true; lastX = x
            } else {
                lastWasActive = false
            }
            return GravitySample(ts: base + i * 30, x: x, y: 0, z: 1)
        }
    }

    func testEmptyGravityIsByteIdenticalToNoGravity() {
        // The degradation contract: with no motion channel NOTHING is masked and the read is
        // unchanged from the pre-gate behaviour.
        var hr: [HRSample] = []
        for h in [8, 9, 10, 11] { hr += hourHR(h, bpm: 60 + (h - 8) * 5) }
        let withoutGravity = DaytimeStress.analyze(hr: hr, rr: [])
        let withEmptyGravity = DaytimeStress.analyze(hr: hr, rr: [], gravity: [])
        XCTAssertEqual(withoutGravity, withEmptyGravity)
        XCTAssertEqual(withEmptyGravity.activityMaskedHours, 0)
        XCTAssertFalse(withEmptyGravity.hours.contains { $0.maskedForActivity })
    }

    func testAmbulatoryHourIsFlaggedButStillScored() {
        // Four hours; the 11:00 hour has an elevated HR AND is ambulatory. FORK BEHAVIOUR: it must
        // still be scored on the curve — real exercise reads as elevated stress, matching WHOOP's own
        // Stress monitor, rather than leaving a gap — but it must still be FLAGGED so the UI/reference
        // can tell it apart from an ordinary tense hour.
        // A LITTLE natural spread across the calm hours (58/60/62, not three identical 60s) — with a
        // zero-spread reference the z-score term is guarded off entirely (`rawScore`'s `sdHR > 0.0001`
        // gate) and 110 bpm would squash to the neutral 1.5 baseline despite being dramatically
        // elevated, which is a reference-construction artifact of the test, not a real product case.
        var hr: [HRSample] = []
        for (h, bpm) in zip([8, 9, 10], [58, 60, 62]) { hr += hourHR(h, bpm: bpm) }
        hr += hourHR(11, bpm: 110)   // the walk

        var gravity: [GravitySample] = []
        for h in [8, 9, 10] { gravity += hourGravity(h, activeFraction: 0.0) }
        gravity += hourGravity(11, activeFraction: 1.0)

        let gated = DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        let flagged = gated.hours.first { $0.hour == 11 }
        XCTAssertNotNil(flagged)
        XCTAssertNotNil(flagged?.level, "an ambulatory hour must still be scored, not left as a gap")
        // > baseline (1.5), not >= highBandFloor: `activityHRSigmaBPM` (60 bpm) deliberately makes an
        // ORDINARY activity elevation read as a gentle rise, not an instant jump to the high band —
        // see that constant's doc comment. This only asserts "elevated, not flat/baseline/dropped".
        XCTAssertGreaterThan(flagged?.level ?? 0, 1.5,
            "110 bpm against a ~60 bpm calm day should read as elevated, same as WHOOP would show it")
        XCTAssertTrue(flagged?.maskedForActivity ?? false,
            "the hour must still report that it included activity, for the UI caption/calm reference")
        XCTAssertEqual(flagged?.meanHR, 110)
        XCTAssertEqual(gated.activityMaskedHours, 1)
    }

    func testStillHourIsStillScoredWhenGravityPresent() {
        // The gate must not swallow a genuinely sedentary day just because gravity was supplied.
        var hr: [HRSample] = []
        var gravity: [GravitySample] = []
        for h in [8, 9, 10, 11] {
            hr += hourHR(h, bpm: h == 11 ? 85 : 60)
            gravity += hourGravity(h, activeFraction: 0.0)
        }
        let r = DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        XCTAssertEqual(r.activityMaskedHours, 0, "a still day must have nothing masked")
        XCTAssertNotNil(r.scored.first { $0.hour == 11 }?.level,
            "a stationary elevated-HR hour is exactly what the timeline SHOULD score")
    }

    func testLightMovementBelowFractionDoesNotMask() {
        // A stray reach or one trip to the kitchen (under activityMaskFraction) is not exertion.
        var hr: [HRSample] = []
        var gravity: [GravitySample] = []
        for h in [8, 9, 10, 11] {
            hr += hourHR(h, bpm: 60)
            gravity += hourGravity(h, activeFraction: h == 10 ? 0.10 : 0.0)
        }
        let r = DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        XCTAssertEqual(r.activityMaskedHours, 0,
            "10 % ambulatory is below activityMaskFraction (0.30) and must not mask the hour")
    }

    func testPostActivityShadowMasksOnlyWhileHRStaysElevated() {
        // The hour AFTER exertion stays FLAGGED while its HR is still above the calm reference by
        // postActivityShadowBPM, and the flag clears once it has recovered. (The flag no longer
        // withholds the score either way — see testAmbulatoryHourIsFlaggedButStillScored.)
        func day(followingBPM: Int) -> DaytimeStress.Result {
            var hr: [HRSample] = []
            var gravity: [GravitySample] = []
            for h in [8, 9, 10, 13] {                       // still hours, set the ~60 bpm calm anchor
                hr += hourHR(h, bpm: 60)
                gravity += hourGravity(h, activeFraction: 0.0)
            }
            hr += hourHR(11, bpm: 120)                      // 11:00 — the workout hour
            gravity += hourGravity(11, activeFraction: 1.0)
            hr += hourHR(12, bpm: followingBPM)             // 12:00 — the shadow hour, now still
            gravity += hourGravity(12, activeFraction: 0.0)
            return DaytimeStress.analyze(hr: hr, rr: [], gravity: gravity)
        }
        // Still elevated well above the ~60 bpm calm reference → flagged.
        let hot = day(followingBPM: 100)
        XCTAssertTrue(hot.hours.first { $0.hour == 12 }?.maskedForActivity ?? false,
            "an unrecovered post-exercise hour must stay flagged")
        // Back at the calm reference → the shadow self-limits and the flag clears.
        let recovered = day(followingBPM: 60)
        XCTAssertFalse(recovered.hours.first { $0.hour == 12 }?.maskedForActivity ?? true,
            "once HR is back at the calm reference the shadow must not keep flagging")
    }

    func testMaskedHoursAreExcludedFromTheCalmReference() {
        // An exertion hour must not drag the day's calm anchor upward, which would depress every
        // other hour's score. Same still hours, with and without an added ambulatory hour.
        var stillHR: [HRSample] = []
        var stillGravity: [GravitySample] = []
        for h in [8, 9, 10, 13] {
            stillHR += hourHR(h, bpm: h == 13 ? 80 : 60)
            stillGravity += hourGravity(h, activeFraction: 0.0)
        }
        let withoutWorkout = DaytimeStress.analyze(hr: stillHR, rr: [], gravity: stillGravity)

        var withHR = stillHR, withGravity = stillGravity
        withHR += hourHR(11, bpm: 130)
        withGravity += hourGravity(11, activeFraction: 1.0)
        let withWorkout = DaytimeStress.analyze(hr: withHR, rr: [], gravity: withGravity)

        let before = withoutWorkout.scored.first { $0.hour == 13 }?.level
        let after = withWorkout.scored.first { $0.hour == 13 }?.level
        XCTAssertNotNil(before); XCTAssertNotNil(after)
        XCTAssertEqual(before!, after!, accuracy: 1e-9,
            "a masked exertion hour leaked into the calm reference and moved an unrelated hour's score")
    }

    func testDifferentGravityDoesNotReuseAMemoizedResult() {
        // The analyze memo is keyed on the streams; two identical hr/rr days with DIFFERENT motion
        // must not share a cached Result.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 60) }
        hr += hourHR(11, bpm: 110)

        var still: [GravitySample] = []
        var moving: [GravitySample] = []
        for h in [8, 9, 10] {
            still += hourGravity(h, activeFraction: 0.0)
            moving += hourGravity(h, activeFraction: 0.0)
        }
        still += hourGravity(11, activeFraction: 0.0)
        moving += hourGravity(11, activeFraction: 1.0)

        let a = DaytimeStress.analyze(hr: hr, rr: [], gravity: still)
        let b = DaytimeStress.analyze(hr: hr, rr: [], gravity: moving)
        XCTAssertEqual(a.activityMaskedHours, 0)
        XCTAssertEqual(b.activityMaskedHours, 1, "the memo key ignored gravity and returned a stale Result")
    }

    // MARK: - Additivity: the `mode` parameter is opt-in, day-relative stays the default

    func testDayRelativeDefaultIsByteIdenticalToExplicitMode() {
        // The additive `mode` parameter defaults to `.dayRelative`. Confirms the implicit call
        // (every pre-existing call site, unmodified) and the explicit `.dayRelative` case
        // produce a BYTE-IDENTICAL `Result` — every field, not just the pre-existing ones —
        // proving the new mode is purely additive and never a silent behaviour change.
        var hr: [HRSample] = []
        for h in [8, 9, 10] { hr += hourHR(h, bpm: 58) }
        hr += hourHR(13, bpm: 120)
        hr += hourHR(14, bpm: 125)
        hr += hourHR(15, bpm: 130)
        var rr: [RRInterval] = []
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)
        rr += hourRRVariable(14, rrMs: 900, jitter: 5)

        let implicit = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: 3_600)
        let explicit = DaytimeStress.analyze(hr: hr, rr: rr, tzOffsetSeconds: 3_600, mode: .dayRelative)
        XCTAssertEqual(implicit, explicit,
            "omitting `mode` must be byte-identical to passing `.dayRelative` explicitly")
    }

    func testHighStressMinutesCountsAllHighBandHoursNotJustTheTrailingRun() {
        // An isolated morning spike, then a calm run ending the day: sustainedHigh only cares
        // about the TRAILING run (and must be false here, since the day ends calm), but
        // highStressMinutes is a day-wide tally and must still count the earlier spike hour —
        // proving it is computed independently, not derived from sustainedRun.
        var hr: [HRSample] = []
        hr += hourHR(7, bpm: 130)   // isolated high spike
        hr += hourHR(8, bpm: 60)
        hr += hourHR(9, bpm: 60)
        hr += hourHR(10, bpm: 60)
        hr += hourHR(11, bpm: 60)   // trailing hour is calm -> NOT sustained
        let r = DaytimeStress.analyze(hr: hr, rr: [])

        XCTAssertFalse(r.sustainedHigh, "the trailing hour is calm, so sustained-high must not fire")
        let expectedHighHours = r.scored.filter { $0.level! >= DaytimeStress.highBandFloor }.count
        XCTAssertGreaterThan(expectedHighHours, 0, "the isolated morning spike should read as high band")
        XCTAssertEqual(r.highStressMinutes, expectedHighHours * (DaytimeStress.bucketSeconds / 60))
        XCTAssertFalse(r.hrOnlyFallback, "day-relative mode never sets the baseline-relative fallback flag")
    }

    // MARK: - Baseline-relative mode (Oura-style, vs a PERSONAL rolling baseline)
    //
    // Fixtures below use a 65 bpm personal HR baseline (matching the ~65 bpm pooled
    // 10th-percentile figure from the validated 26-day Oura-reference correlation — see
    // `DaytimeStress.baselineRelativeHighMarginBPM`) and elevations measured from it in terms of
    // that validated ~15 bpm margin, so the expected band crossings are exact, not approximate.

    func testMarginToSigmaLandsExactlyOnBand() {
        // The validated 15 bpm margin over baseline must land EXACTLY on highBandFloor (2.0) on
        // the shared squash curve — the core identity `.baselineRelative` scoring relies on.
        let sd = DaytimeStress.marginToSigma(marginBPM: DaytimeStress.baselineRelativeHighMarginBPM,
                                             atBand: DaytimeStress.highBandFloor)
        XCTAssertEqual(DaytimeStress.squash(DaytimeStress.baselineRelativeHighMarginBPM / sd),
                      DaytimeStress.highBandFloor, accuracy: 1e-9)
    }

    func testBaselineRelativeModeRecoversMultipleInjectedElevations() {
        // Personal daytime-HR baseline: 20 constant "days" at 65 bpm converges the EWMA center
        // to exactly 65 (spread is folded but NOT used for the HR high-band threshold — see
        // baselineRelativeHighMarginBPM).
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        XCTAssertEqual(hrBaseline.baseline, 65.0, accuracy: 1e-6)

        // FOUR distinct injected HR elevations across the SAME day's waking hours — the repo's
        // derived-signal rule (CLAUDE.md "validate against the artifact, not one match") requires
        // recovering MULTIPLE injected values, not a single high-vs-low pair. 65 (at baseline),
        // 72 (+7, mild), 80 (+15, exactly the validated margin), 95 (+30, well past it).
        let levels: [(hour: Int, bpm: Int)] = [(8, 65), (10, 72), (13, 80), (16, 95)]
        var hr: [HRSample] = []
        for (h, bpm) in levels { hr += hourHR(h, bpm: bpm) }

        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))
        let scores = levels.map { pair in r.scored.first { $0.hour == pair.hour }!.level! }

        // Strictly increasing with the injected elevation — all four levels recovered, in order.
        for i in 1..<scores.count {
            XCTAssertGreaterThan(scores[i], scores[i - 1],
                "hour \(levels[i].hour) (\(levels[i].bpm) bpm) should score higher than hour \(levels[i - 1].hour) (\(levels[i - 1].bpm) bpm)")
        }
        // The at-baseline hour reads at the 1.5 midpoint; +15 bpm (the validated margin) lands
        // exactly on highBandFloor; the most-elevated hour clears well past it.
        XCTAssertEqual(scores[0], 1.5, accuracy: 0.05)
        XCTAssertEqual(scores[2], DaytimeStress.highBandFloor, accuracy: 0.01,
            "the validated +15 bpm margin should land exactly on highBandFloor")
        XCTAssertGreaterThan(scores.last!, DaytimeStress.highBandFloor)
        XCTAssertTrue(r.hrOnlyFallback, "rmssd: nil must flag the HR-only fallback")
    }

    func testBaselineRelativeCalmDayAtPersonalBaselineReadsLowNotHigh() {
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        var hr: [HRSample] = []
        for h in [8, 10, 13, 16] { hr += hourHR(h, bpm: 65) }   // every hour sits exactly at baseline
        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))

        for p in r.scored {
            XCTAssertEqual(p.level!, 1.5, accuracy: 0.05,
                "a day flat at the personal baseline should read ~1.5, not elevated")
        }
        XCTAssertEqual(r.highStressMinutes, 0)
        XCTAssertFalse(r.sustainedHigh)
    }

    func testBaselineRelativeElevatedDayProducesHighStressMinutes() {
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        var hr: [HRSample] = []
        for h in 8...16 { hr += hourHR(h, bpm: 95) }   // +30 bpm — twice the validated high-band margin
        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))

        XCTAssertGreaterThan(r.highStressMinutes, 0)
        XCTAssertEqual(r.highStressMinutes,
                      r.scored.filter { $0.level! >= DaytimeStress.highBandFloor }.count * (DaytimeStress.bucketSeconds / 60))
        for p in r.scored { XCTAssertGreaterThanOrEqual(p.level!, DaytimeStress.highBandFloor) }
    }

    func testBaselineRelativeNilRMSSDFallsBackToHROnlyAndFlagsDegraded() {
        // An imported, Oura-era day: no personal RMSSD baseline exists yet (rmssd: nil) and no
        // R-R stream is available either. The read must still complete honestly, never crash.
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        var hr: [HRSample] = []
        for h in [9, 14] { hr += hourHR(h, bpm: 80) }   // right at the validated +15 bpm margin
        let r = DaytimeStress.analyze(hr: hr, rr: [], mode: .baselineRelative(hr: hrBaseline, rmssd: nil))

        XCTAssertTrue(r.hrOnlyFallback)
        XCTAssertFalse(r.scored.isEmpty, "HR-only scoring must still produce a timeline")
        for p in r.scored { XCTAssertNotNil(p.level) }
    }

    func testBaselineRelativeUsesRMSSDBaselineWhenAvailable() {
        // Personal baselines: HR steady at 65 bpm, RMSSD steady at 40 ms (both spread-floored).
        let hrBaseline = Baselines.foldHistory(Array(repeating: 65.0, count: 20), cfg: Baselines.daytimeHRCfg)
        let rmssdBaseline = Baselines.foldHistory(Array(repeating: 40.0, count: 20), cfg: Baselines.daytimeRMSSDCfg)

        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        for h in [9, 14] { hr += hourHR(h, bpm: 65) }        // HR AT baseline in both hours — isolates RMSSD
        rr += hourRRVariable(9, rrMs: 900, jitter: 40)        // normal variability
        rr += hourRRVariable(14, rrMs: 900, jitter: 2)        // suppressed HRV -> more stressed

        let r = DaytimeStress.analyze(hr: hr, rr: rr,
                                      mode: .baselineRelative(hr: hrBaseline, rmssd: rmssdBaseline))
        XCTAssertFalse(r.hrOnlyFallback, "an RMSSD baseline was supplied — no fallback")
        let normal = r.scored.first { $0.hour == 9 }!.level!
        let suppressed = r.scored.first { $0.hour == 14 }!.level!
        XCTAssertGreaterThan(suppressed, normal,
            "suppressed RMSSD vs. the personal baseline should read MORE stressed than normal variability")
    }
}
