import Foundation
import WhoopProtocol

// BedtimeBreathingGate.swift — "you look settled in bed" for the evening breathing nudge.
//
// Fork addition. Pure: decides from the strap's recent HR and gravity whether the wearer looks lying
// still and winding down inside the evening window, so the iOS app can suggest a coherence session.
// A wrist cannot tell lying from sitting still for sure, so the gate asks for stillness AND a heart
// rate already near the resting level, and it only ever suggests; it never acts.

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
    /// HR, median of the last 10 minutes, must sit at most this far above resting HR (bpm).
    public static let maxBpmAboveResting = 15.0
    /// Without a resting HR, the last 10 minutes must sit at least this far below the earlier minutes.
    public static let minBpmDropWithoutResting = 3.0

    public enum Verdict: Equatable, Sendable {
        case nudge
        case outsideWindow
        case notEnoughData
        case moving
        case heartRateHigh
    }

    /// - Parameters:
    ///   - now: unix seconds.
    ///   - localMinuteOfDay: the wearer's local minutes since midnight at `now`.
    ///   - hr, grav: the strap's samples; only the last `lookbackSeconds` are read.
    ///   - restingHR: the wearer's resting HR, if known.
    public static func evaluate(now: Int, localMinuteOfDay: Int, hr: [HRSample], grav: [GravitySample],
                                restingHR: Double?) -> Verdict {
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

        let recent = h.filter { $0.ts > now - 10 * 60 }.map { Double($0.bpm) }
        guard let recentMedian = median(recent) else { return .notEnoughData }
        if let resting = restingHR, resting > 0 {
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
