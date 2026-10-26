import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The breathing tab's pure parts: RR-derived breathing rate and coherence (`BreathingSignal`), the
/// exercise list (`BreathingScienceCatalog`) and the bedtime nudge gate (`BedtimeBreathingGate`).
final class BreathingSignalTests: XCTestCase {

    /// R-R intervals around `meanMs`, modulated by a sine at `breathHz` (the RSA a breath produces), over
    /// `seconds` of beats.
    private func rsaBeats(meanMs: Double = 1000, amplitudeMs: Double = 80, breathHz: Double, seconds: Double) -> [Double] {
        var out: [Double] = []
        var t = 0.0
        while t < seconds {
            let rr = meanMs + amplitudeMs * sin(2 * Double.pi * breathHz * t)
            out.append(rr)
            t += rr / 1000
        }
        return out
    }

    /// Deterministic irregular R-R: a linear congruential generator, no shared RNG state.
    private func noisyBeats(count: Int) -> [Double] {
        var state: UInt64 = 12_345
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let u = Double((state >> 33) % 1000) / 1000.0
            return 950 + 100 * u
        }
    }

    // MARK: - Breathing rate

    func testSixBreathsPerMinuteIsRecovered() throws {
        let bpm = try XCTUnwrap(BreathingSignal.breathsPerMinute(rrMs: rsaBeats(breathHz: 0.1, seconds: 60)))
        XCTAssertEqual(bpm, 6.0, accuracy: 0.3)
    }

    func testFifteenBreathsPerMinuteIsRecovered() throws {
        let bpm = try XCTUnwrap(BreathingSignal.breathsPerMinute(rrMs: rsaBeats(breathHz: 0.25, seconds: 60)))
        XCTAssertEqual(bpm, 15.0, accuracy: 0.5)
    }

    /// Several injected rates, not one, so a method that only matched one case cannot pass.
    func testRateTracksAVaryingInput() throws {
        for breathsPerMin in [4.5, 6.0, 8.0, 10.0, 12.0, 18.0] {
            let got = try XCTUnwrap(BreathingSignal.breathsPerMinute(
                rrMs: rsaBeats(breathHz: breathsPerMin / 60, seconds: 90)))
            XCTAssertEqual(got, breathsPerMin, accuracy: 0.6, "injected \(breathsPerMin)")
        }
    }

    func testTooFewBeatsGiveNoEstimate() {
        XCTAssertNil(BreathingSignal.breathsPerMinute(rrMs: rsaBeats(breathHz: 0.1, seconds: 20)))
        XCTAssertNil(BreathingSignal.breathsPerMinute(rrMs: []))
        XCTAssertNil(BreathingSignal.coherence(rrMs: Array(repeating: 1000, count: 10)))
    }

    // MARK: - Coherence

    func testSlowRegularBreathingIsCoherentAndNoiseIsNot() throws {
        let coherent = try XCTUnwrap(BreathingSignal.coherence(rrMs: rsaBeats(breathHz: 0.1, seconds: 64)))
        let noisy = try XCTUnwrap(BreathingSignal.coherence(rrMs: noisyBeats(count: 70)))
        XCTAssertGreaterThan(coherent, 70)
        XCTAssertLessThan(noisy, 40)
        XCTAssertGreaterThan(coherent, noisy)
    }

    /// A perfectly regular breath fills the scale: the peak window spans the Hann main lobe.
    func testAPerfectBreathScoresNearTheTop() throws {
        for breathsPerMin in [5.0, 6.0, 7.0] {
            let c = try XCTUnwrap(BreathingSignal.coherence(rrMs: rsaBeats(breathHz: breathsPerMin / 60, seconds: 64)))
            XCTAssertGreaterThan(c, 90, "\(breathsPerMin)/min")
        }
        XCTAssertEqual(BreathingSignal.peakHalfWidthHz(spanSeconds: 64), 2.0 / 64, accuracy: 1e-12)
        XCTAssertEqual(BreathingSignal.peakHalfWidthHz(spanSeconds: 600), BreathingSignal.coherencePeakHalfWidthHz)
    }

    /// Paced breathing with a slow drift and beat jitter, as a real strap records it, still reads as
    /// coherent; breathing whose length changes every breath does not.
    func testRealisticPacedBreathIsCoherentAndIrregularBreathIsNot() throws {
        var state: UInt64 = 777
        func jitter() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) % 1000) / 1000.0 - 0.5
        }
        // 6/min RSA (±40 ms), a 0.02 Hz drift (±25 ms) and ±10 ms of beat jitter.
        var paced: [Double] = []
        var t = 0.0
        while t < 64 {
            let rr = 950 + 40 * sin(2 * Double.pi * 0.1 * t) + 25 * sin(2 * Double.pi * 0.02 * t) + 20 * jitter()
            paced.append(rr); t += rr / 1000
        }
        // Each breath 3 to 7 s long, chosen anew, same RSA depth and jitter.
        var irregular: [Double] = []
        t = 0
        var phase = 0.0, breathStart = 0.0, period = 5.0
        while t < 64 {
            if t - breathStart >= period { breathStart = t; period = 3 + 4 * (jitter() + 0.5) }
            phase = (t - breathStart) / period
            let rr = 950 + 40 * sin(2 * Double.pi * phase) + 20 * jitter()
            irregular.append(rr); t += rr / 1000
        }
        let good = try XCTUnwrap(BreathingSignal.coherence(rrMs: paced))
        let bad = try XCTUnwrap(BreathingSignal.coherence(rrMs: irregular))
        XCTAssertGreaterThan(good, 60)
        XCTAssertLessThan(bad, 55)
        XCTAssertGreaterThan(good - bad, 25)
    }

    // MARK: - Catalog

    func testCatalogIdsAreUniqueAndPacedDrillsPlay() {
        let ids = BreathingScienceCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for ex in BreathingScienceCatalog.all {
            XCTAssertGreaterThanOrEqual(ex.benefits.count, 2, "\(ex.id) needs its benefit points")
            if case .paced = ex.drill {
                let proto = ex.asProtocol()
                XCTAssertNotNil(proto, ex.id)
                XCTAssertFalse(BreathProtocolPlayer.schedule(proto!, sessionMs: 60_000).isEmpty, ex.id)
            }
        }
    }

    func testPacedRatesMatchTheirLabels() throws {
        func rate(_ id: String) throws -> Double {
            try XCTUnwrap(BreathingScienceCatalog.exercise(id)?.pacedBreathsPerMinute)
        }
        XCTAssertEqual(try rate(BreathingScienceCatalog.coherenceId), 6.0, accuracy: 1e-9)
        XCTAssertEqual(try rate(BreathingScienceCatalog.sleepId), 5.0, accuracy: 1e-9)
        XCTAssertEqual(try rate(BreathingScienceCatalog.co2Id), 60.0 / 22.0, accuracy: 1e-9)
        // The double inhale of the cyclic sigh is one breath: 9 s per breath.
        XCTAssertEqual(try rate(BreathingScienceCatalog.cyclicSighId), 60.0 / 9.0, accuracy: 1e-9)
    }

    func testResonancePacedUsesTheLockedPace() throws {
        let ex = try XCTUnwrap(BreathingScienceCatalog.exercise(BreathingScienceCatalog.resonanceId))
        let locked = try XCTUnwrap(ex.asProtocol(resonanceBpm: 5.0))
        XCTAssertEqual(locked.cycleDurationMs, 12_000)
        let fallback = try XCTUnwrap(ex.asProtocol())
        XCTAssertEqual(fallback.cycleDurationMs, Int((60_000.0 / ResonanceEngine.fallbackBpm / 2).rounded()) * 2)
    }

    // MARK: - Bedtime gate

    private let now = 1_749_500_000

    private func still(minutes: Int, z: Double = 1.0) -> [GravitySample] {
        (0..<(minutes * 60)).map { GravitySample(ts: now - $0, x: 0, y: 0, z: z) }
    }

    private func hr(_ bpm: Int, from: Int, to: Int) -> [HRSample] {
        stride(from: now - from, to: now - to, by: 5).map { HRSample(ts: $0, bpm: bpm) }
    }

    func testStillAndCalmInTheWindowNudges() {
        let v = BedtimeBreathingGate.evaluate(now: now, localMinuteOfDay: 22 * 60, hr: hr(60, from: 900, to: 0),
                                              grav: still(minutes: 15), restingHR: 52)
        XCTAssertEqual(v, .nudge)
    }

    func testOutsideTheWindowNeverNudges() {
        for minute in [20 * 60 + 59, 23 * 60, 3 * 60] {
            XCTAssertEqual(BedtimeBreathingGate.evaluate(now: now, localMinuteOfDay: minute,
                                                         hr: hr(60, from: 900, to: 0), grav: still(minutes: 15),
                                                         restingHR: 52), .outsideWindow)
        }
    }

    func testMovingOrFastHeartDoesNotNudge() {
        let moving = (0..<900).map { GravitySample(ts: now - $0, x: $0 % 2 == 0 ? 0.3 : -0.3, y: 0, z: 0.9) }
        XCTAssertEqual(BedtimeBreathingGate.evaluate(now: now, localMinuteOfDay: 22 * 60, hr: hr(60, from: 900, to: 0),
                                                     grav: moving, restingHR: 52), .moving)
        XCTAssertEqual(BedtimeBreathingGate.evaluate(now: now, localMinuteOfDay: 22 * 60, hr: hr(80, from: 900, to: 0),
                                                     grav: still(minutes: 15), restingHR: 52), .heartRateHigh)
        XCTAssertEqual(BedtimeBreathingGate.evaluate(now: now, localMinuteOfDay: 22 * 60, hr: hr(60, from: 900, to: 0),
                                                     grav: still(minutes: 5), restingHR: 52), .notEnoughData)
    }

    func testWithoutRestingHRAFallingHeartRateNudges() {
        let falling = hr(70, from: 900, to: 600) + hr(62, from: 600, to: 0)
        XCTAssertEqual(BedtimeBreathingGate.evaluate(now: now, localMinuteOfDay: 22 * 60, hr: falling,
                                                     grav: still(minutes: 15), restingHR: nil), .nudge)
        let flat = hr(70, from: 900, to: 0)
        XCTAssertEqual(BedtimeBreathingGate.evaluate(now: now, localMinuteOfDay: 22 * 60, hr: flat,
                                                     grav: still(minutes: 15), restingHR: nil), .heartRateHigh)
    }
}

/// Levels of the training drills (`BreathingProgression`).
final class BreathingProgressionTests: XCTestCase {
    private let co2 = BreathingScienceCatalog.co2Id
    private let holds = BreathingScienceCatalog.breathHoldsId
    private let muscle = BreathingScienceCatalog.respiratoryMuscleId

    func testOnlyTrainingDrillsProgress() {
        XCTAssertTrue(BreathingProgression.isProgressive(co2))
        XCTAssertTrue(BreathingProgression.isProgressive(holds))
        XCTAssertTrue(BreathingProgression.isProgressive(muscle))
        for id in [BreathingScienceCatalog.coherenceId, BreathingScienceCatalog.cyclicSighId,
                   BreathingScienceCatalog.sleepId, BreathingScienceCatalog.boxId, BreathingScienceCatalog.airwaysId] {
            XCTAssertFalse(BreathingProgression.isProgressive(id), id)
            let base = BreathingScienceCatalog.exercise(id)!
            XCTAssertEqual(BreathingProgression.exercise(base, level: 4), base)
        }
    }

    func testLevelOneIsTheCatalogDrill() {
        for id in [co2, holds, muscle] {
            let base = BreathingScienceCatalog.exercise(id)!
            XCTAssertEqual(BreathingProgression.exercise(base, level: 1), base, id)
        }
    }

    func testDoseGrowsWithLevelAndCaps() {
        XCTAssertEqual((1...5).map { BreathingProgression.co2HoldSeconds(level: $0) }, [10, 15, 20, 25, 30])
        XCTAssertEqual(BreathingProgression.co2HoldSeconds(level: 9), 30)
        XCTAssertEqual((1...6).map { BreathingProgression.breathHolds(level: $0).rounds }, [5, 7, 9, 11, 13, 15])
        XCTAssertEqual(BreathingProgression.breathHolds(level: 6).maxHoldSeconds, 300)
        XCTAssertEqual((1...7).map { BreathingProgression.muscleBreaths(level: $0) }, [30, 35, 40, 45, 50, 55, 60])
        let lvl3 = BreathingProgression.exercise(BreathingScienceCatalog.exercise(co2)!, level: 3)
        XCTAssertEqual(lvl3.asProtocol()?.cycleDurationMs, 6_000 + 6_000 + 20_000)
        let m = BreathingProgression.exercise(BreathingScienceCatalog.exercise(muscle)!, level: 3)
        XCTAssertEqual(m.guidedSeconds, 40 * 6)
    }

    func testOnlyFullSessionsEarnTheNextLevel() {
        var s = BreathingProgression.State()
        s = BreathingProgression.afterSession(s, id: co2, completedFully: false).state
        XCTAssertEqual(s, .init(level: 1, completions: 0))
        s = BreathingProgression.afterSession(s, id: co2, completedFully: true).state
        s = BreathingProgression.afterSession(s, id: co2, completedFully: true).state
        let third = BreathingProgression.afterSession(s, id: co2, completedFully: true)
        XCTAssertTrue(third.leveledUp)
        XCTAssertEqual(third.state, .init(level: 2, completions: 0))
        // The top level never moves past its cap.
        let top = BreathingProgression.afterSession(.init(level: 5, completions: 2), id: co2, completedFully: true)
        XCTAssertFalse(top.leveledUp)
        XCTAssertEqual(top.state.level, 5)
        // Six sessions per level for the muscle drill.
        XCTAssertEqual(BreathingProgression.sessionsPerLevel(muscle), 6)
        // Stepping down restarts the count and never goes below 1.
        XCTAssertEqual(BreathingProgression.stepDown(.init(level: 3, completions: 2), id: co2), .init(level: 2, completions: 0))
        XCTAssertEqual(BreathingProgression.stepDown(.init(level: 1, completions: 1), id: co2).level, 1)
        // A calming drill never counts.
        XCTAssertFalse(BreathingProgression.afterSession(.init(), id: BreathingScienceCatalog.coherenceId,
                                                         completedFully: true).leveledUp)
    }
}
