import Foundation
import WhoopProtocol

// BedtimeBreathingGate.swift — "you look settled in bed" for the evening breathing nudge.
//
// Fork addition. Pure: decides from the strap's recent HR, gravity and (when the strap reports it) its
// own band sleep state whether the wearer looks lying still and still AWAKE inside the evening window,
// so the iOS app can suggest a coherence session. It only ever suggests; it never acts.
//
// Awake is the point: a nudge that lands once the wearer is asleep wakes them. The first version waited
// for heart rate to come down near resting, which on the wearer who asked for it only happened once they
// were asleep (lying awake 68–70 bpm, asleep 57–61, resting about 50). So the heart-rate test now runs
// the other way: a heart already at sleep level means "probably asleep, stay quiet". When the strap
// reports its band state (WHOOP 5/MG: 0 wake, 1 still, 2 asleep, 3 up), that decides instead: "still"
// is lying at rest and awake, "asleep" blocks the nudge. On that same evening the band read "still"
// from 23:26 and "asleep" from 23:52, matching the wearer's own account of falling asleep near 23:40.

public enum BedtimeBreathingGate {

    /// Local minutes since midnight the nudge may fire in: 21:00 to 23:00.
    public static let windowMinutes: Range<Int> = (21 * 60)..<(23 * 60)
    /// Look-back read from the strap, seconds.
    public static let lookbackSeconds = 15 * 60
    /// Minutes of the look-back that must carry data.
    public static let minCoveredMinutes = 10
    /// Share of covered minutes that must be still.
    public static let minStillFraction = 0.8
    /// A minute is still when its gravity samples stay within this distance (g) of their mean.
    public static let stillMaxDeviationG = 0.05
    /// HR (median of the last 10 minutes) at or below resting + this is sleep level: no nudge (bpm).
    public static let asleepMaxBpmAboveResting = 4.0
    /// HR above resting + this is not winding down (bpm).
    public static let maxBpmAboveResting = 30.0
    /// Without a resting HR, the last 10 minutes must sit at least this far below the earlier minutes.
    public static let minBpmDropWithoutResting = 3.0
    /// Band state codes (the strap's own, `(byte >> 4) & 3`).
    public static let bandStill = 1
    public static let bandAsleep = 2
    /// Band "asleep" in this many final seconds blocks the nudge.
    public static let bandAsleepLookbackSeconds = 5 * 60
    /// Share of the last 10 minutes of band states that must read "still" for a band-based nudge.
    public static let minBandStillFraction = 0.6

    public enum Verdict: Equatable, Sendable {
        case nudge
        case outsideWindow
        case notEnoughData
        case moving
        case heartRateHigh
        /// The wearer already looks asleep: a nudge would wake them.
        case asleep
    }

    /// - Parameters:
    ///   - now: unix seconds.
    ///   - localMinuteOfDay: the wearer's local minutes since midnight at `now`.
    ///   - hr, grav: the strap's samples; only the last `lookbackSeconds` are read.
    ///   - restingHR: the wearer's resting HR, if known.
    ///   - bandStates: the strap's own sleep state per second, when it reports one (empty otherwise).
    public static func evaluate(now: Int, localMinuteOfDay: Int, hr: [HRSample], grav: [GravitySample],
                                restingHR: Double?, bandStates: [(ts: Int, state: Int)] = []) -> Verdict {
        guard windowMinutes.contains(localMinuteOfDay) else { return .outsideWindow }
        let from = now - lookbackSeconds
        let g = grav.filter { $0.ts > from && $0.ts <= now }
        let h = hr.filter { $0.ts > from && $0.ts <= now && $0.bpm > 0 }

        var byMinute: [Int: [GravitySample]] = [:]
        for s in g { byMinute[(s.ts - from) / 60, default: []].append(s) }
        let covered = byMinute.values.filter { !$0.isEmpty }
        guard covered.count >= minCoveredMinutes, h.count >= 10 else { return .notEnoughData }
        let still = covered.filter(isStill).count
        guard Double(still) / Double(covered.count) >= minStillFraction else { return .moving }

        // The strap's own state, when present, decides awake versus asleep.
        let band = bandStates.filter { $0.ts > now - 10 * 60 && $0.ts <= now }
        if !band.isEmpty {
            if band.contains(where: { $0.state == bandAsleep && $0.ts > now - bandAsleepLookbackSeconds }) {
                return .asleep
            }
            let stillShare = Double(band.filter { $0.state == bandStill }.count) / Double(band.count)
            if stillShare >= minBandStillFraction { return .nudge }
        }

        let recent = h.filter { $0.ts > now - 10 * 60 }.map { Double($0.bpm) }
        guard let recentMedian = median(recent) else { return .notEnoughData }
        if let resting = restingHR, resting > 0 {
            if recentMedian <= resting + asleepMaxBpmAboveResting { return .asleep }
            return recentMedian <= resting + maxBpmAboveResting ? .nudge : .heartRateHigh
        }
        let earlier = h.filter { $0.ts <= now - 10 * 60 }.map { Double($0.bpm) }
        guard let earlierMedian = median(earlier) else { return .notEnoughData }
        return recentMedian <= earlierMedian - minBpmDropWithoutResting ? .nudge : .heartRateHigh
    }

    static func isStill(_ minute: [GravitySample]) -> Bool {
        let n = Double(minute.count)
        let mx = minute.reduce(0) { $0 + $1.x } / n
        let my = minute.reduce(0) { $0 + $1.y } / n
        let mz = minute.reduce(0) { $0 + $1.z } / n
        return minute.allSatisfy { s in
            let dx = s.x - mx, dy = s.y - my, dz = s.z - mz
            return (dx * dx + dy * dy + dz * dz).squareRoot() <= stillMaxDeviationG
        }
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
