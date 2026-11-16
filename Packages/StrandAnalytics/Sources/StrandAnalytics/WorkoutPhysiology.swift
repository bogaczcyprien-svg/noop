import Foundation
import WhoopProtocol

// WorkoutPhysiology.swift — FORK-ONLY, not ported to Android. The numbers behind the per-session
// debrief page: time-in-zone, an aerobic and an anaerobic training-effect ESTIMATE on a 0-5 scale, the
// session's main benefit, hard efforts and cardiac drift. Heart rate only, pure, no store.
//
// Zones are the app's ONE display-zone model (`HRZoneSet`: the user's own BPM boundaries when set in
// Settings, else the conventional %HRmax bands), counted with the same sample-duration rule as
// `HRZones.timeInZone`, so the debrief and the workout detail screen show the same minutes.
//
// The two effect scores are NOOP's own transparent approximation, not Firstbeat/Garmin Training Effect
// (whose model is proprietary): the aerobic effect maps an Edwards zone-weighted load (minutes x zone
// number) onto 0-5, and the anaerobic effect maps the minutes spent in zone 5 and the top half of zone 4.
// The page labels them as estimates. They are shown and sent to the AI coach only — never stored, never
// fed into Charge, Effort or any other score.
public enum WorkoutPhysiology {

    /// A hard effort: at least this long at or above the middle of zone 4.
    public static let hardEffortMinS: Double = 30
    /// Drift is only meaningful on a long, mostly steady session.
    public static let driftMinDurationS: Double = 30 * 60
    public static let driftMaxHardEfforts = 3

    /// Edwards load -> aerobic effect (piecewise linear).
    static let aerobicCurve: [(load: Double, te: Double)] = [
        (0, 0), (20, 1), (50, 2), (100, 3), (170, 4), (260, 5)
    ]
    /// Anaerobic minutes -> anaerobic effect (piecewise linear).
    static let anaerobicCurve: [(minutes: Double, te: Double)] = [
        (0, 0), (1, 0.8), (3, 1.8), (6, 2.6), (12, 3.5), (20, 4.3), (30, 5)
    ]

    public enum Benefit: String, Sendable, Equatable {
        case recovery, base, tempo, threshold, vo2max, anaerobic

        public var labelFR: String {
            switch self {
            case .recovery:  return "Récupération"
            case .base:      return "Endurance de base"
            case .tempo:     return "Tempo"
            case .threshold: return "Seuil"
            case .vo2max:    return "VO2max"
            case .anaerobic: return "Capacité anaérobie"
            }
        }
    }

    public struct Result: Sendable, Equatable {
        /// BPM where zones 1-5 start, as used.
        public let zoneLowerBoundsBPM: [Double]
        public let maxHRUsed: Double
        /// Minutes below zone 1 at index 0, then zones 1-5 at indexes 1-5.
        public let zoneMinutes: [Double]
        public let totalMinutes: Double
        /// Edwards load: zone minutes weighted by zone number (1-5).
        public let edwardsLoad: Double
        public let aerobicEffect: Double
        public let anaerobicEffect: Double
        /// Share of the session above the middle of zone 4 (the estimated anaerobic threshold), 0-100.
        public let anaerobicSharePct: Double
        public let benefit: Benefit
        public let hardEfforts: Int
        public let meanHR: Double
        public let peakHR: Int
        /// Highest 60-second mean heart rate.
        public let peak60sHR: Double?
        /// Second-half vs first-half mean HR, %, on a long steady session; nil otherwise.
        public let driftPct: Double?
    }

    /// 0-5 effect words, shared by both effects.
    public static func effectLabelFR(_ te: Double) -> String {
        switch te {
        case ..<1.0: return "Aucun effet"
        case ..<2.0: return "Effet léger"
        case ..<3.0: return "Entretien"
        case ..<4.0: return "Améliore"
        case ..<5.0: return "Améliore beaucoup"
        default:     return "Surcharge"
        }
    }

    static func interpolate(_ x: Double, _ curve: [(Double, Double)]) -> Double {
        guard let first = curve.first, let last = curve.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<curve.count {
            let (x0, y0) = curve[i - 1]
            let (x1, y1) = curve[i]
            if x <= x1 { return x1 > x0 ? y0 + (x - x0) / (x1 - x0) * (y1 - y0) : y1 }
        }
        return last.1
    }

    public static func aerobicEffect(edwardsLoad: Double) -> Double {
        round1(interpolate(max(0, edwardsLoad), aerobicCurve.map { ($0.load, $0.te) }))
    }

    /// Anaerobic minutes = minutes in zone 5 + 0.3 x minutes in the top half of zone 4.
    public static func anaerobicEffect(anaerobicMinutes: Double, hardEfforts: Int) -> Double {
        let base = interpolate(max(0, anaerobicMinutes), anaerobicCurve.map { ($0.minutes, $0.te) })
        // Repeated hard efforts tax the glycolytic system more than one block of the same length.
        let bonus = base > 0 ? min(0.5, Double(max(0, hardEfforts - 3)) * 0.1) : 0
        return round1(min(5, base + bonus))
    }

    public static func benefit(zoneMinutes: [Double], aerobicEffect: Double, anaerobicEffect: Double) -> Benefit {
        let total = zoneMinutes.reduce(0, +)
        guard total > 0 else { return .recovery }
        func frac(_ z: Int) -> Double { zoneMinutes[z] / total }
        if anaerobicEffect >= 3.0 { return .anaerobic }
        if frac(5) >= 0.15 { return .vo2max }
        if frac(4) >= 0.25 || frac(4) + frac(5) >= 0.30 { return .threshold }
        if frac(3) >= 0.30 { return .tempo }
        if aerobicEffect >= 2.0 { return .base }
        return .recovery
    }

    /// Per-sample durations (s), the `HRZones.timeInZone` rule: the gap to the next sample capped at the
    /// median spacing, and the last sample takes the median.
    static func durations(_ hr: [HRSample]) -> [Double] {
        let median = HRZones.medianInterval(hr)
        return hr.indices.map { i in
            guard i < hr.count - 1 else { return median }
            let gap = Double(hr[i + 1].ts - hr[i].ts)
            return gap > 0 ? min(gap, median) : median
        }
    }

    /// Analyse one session against `zoneSet`. nil when there are no plausible samples.
    public static func analyse(hr raw: [HRSample], zoneSet: HRZoneSet) -> Result? {
        let hr = raw.filter { (25...240).contains($0.bpm) }.sorted { $0.ts < $1.ts }
        guard !hr.isEmpty, zoneSet.zones.count == 5 else { return nil }
        let bounds = zoneSet.zones.map { $0.lower }
        let z4 = bounds[3], z5 = bounds[4]
        let threshold = (z4 + z5) / 2   // ~85 % of the way up the default bands
        let dur = durations(hr)
        var zones = [Double](repeating: 0, count: 6)
        var anaerobicS = 0.0
        var anaerobicMinutes = 0.0
        var sumHR = 0.0, sumW = 0.0
        var efforts = 0
        var inEffort = false, effortS = 0.0, counted = false
        for (i, s) in hr.enumerated() {
            let bpm = Double(s.bpm)
            let d = dur[i]
            zones[zoneSet.zoneNumber(forBPM: bpm)] += d / 60
            if bpm >= threshold { anaerobicS += d }
            if bpm >= z5 { anaerobicMinutes += d / 60 } else if bpm >= threshold { anaerobicMinutes += 0.3 * d / 60 }
            sumHR += Double(s.bpm) * d; sumW += d
            if bpm >= threshold {
                if !inEffort { inEffort = true; effortS = 0; counted = false }
                effortS += d
                if !counted && effortS >= hardEffortMinS { efforts += 1; counted = true }
            } else if bpm < z4 {
                inEffort = false
            }
        }
        let total = zones.reduce(0, +)
        let load = (1...5).reduce(0.0) { $0 + zones[$1] * Double($1) }
        let ae = aerobicEffect(edwardsLoad: load)
        let an = anaerobicEffect(anaerobicMinutes: anaerobicMinutes, hardEfforts: efforts)
        let spanS = Double(hr.last!.ts - hr.first!.ts)
        return Result(
            zoneLowerBoundsBPM: bounds, maxHRUsed: zoneSet.maxHR,
            zoneMinutes: zones.map(round1), totalMinutes: round1(total),
            edwardsLoad: round1(load), aerobicEffect: ae, anaerobicEffect: an,
            anaerobicSharePct: sumW > 0 ? round1(anaerobicS / sumW * 100) : 0,
            benefit: benefit(zoneMinutes: zones, aerobicEffect: ae, anaerobicEffect: an),
            hardEfforts: efforts,
            meanHR: sumW > 0 ? round1(sumHR / sumW) : 0,
            peakHR: hr.map(\.bpm).max() ?? 0,
            peak60sHR: peakWindowMean(hr, windowS: 60).map(round1),
            driftPct: (spanS >= driftMinDurationS && efforts <= driftMaxHardEfforts) ? drift(hr).map(round1) : nil)
    }

    /// Highest mean HR over any `windowS`-second window (two-pointer), nil when the session is shorter.
    static func peakWindowMean(_ hr: [HRSample], windowS: Int) -> Double? {
        guard let first = hr.first, let last = hr.last, last.ts - first.ts >= windowS else { return nil }
        var best: Double?
        var lo = 0
        var sum = 0
        for hi in 0..<hr.count {
            sum += hr[hi].bpm
            while hr[hi].ts - hr[lo].ts > windowS { sum -= hr[lo].bpm; lo += 1 }
            if hr[hi].ts - first.ts >= windowS {
                let m = Double(sum) / Double(hi - lo + 1)
                if best == nil || m > best! { best = m }
            }
        }
        return best
    }

    /// Mean HR of the second half against the first half, in %. The first 10 % is skipped as warm-up.
    static func drift(_ hr: [HRSample]) -> Double? {
        guard let first = hr.first, let last = hr.last else { return nil }
        let start = first.ts + (last.ts - first.ts) / 10
        let mid = start + (last.ts - start) / 2
        let a = hr.filter { $0.ts >= start && $0.ts < mid }.map { Double($0.bpm) }
        let b = hr.filter { $0.ts >= mid }.map { Double($0.bpm) }
        guard a.count >= 10, b.count >= 10 else { return nil }
        let ma = a.reduce(0, +) / Double(a.count)
        let mb = b.reduce(0, +) / Double(b.count)
        return ma > 0 ? (mb - ma) / ma * 100 : nil
    }

    static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}
