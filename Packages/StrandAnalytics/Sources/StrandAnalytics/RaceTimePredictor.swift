import Foundation

// RaceTimePredictor.swift — fork addition (not upstream). Estimates race finish times from the
// already-computed VO2max estimate (`FitnessAgeEngine`/`vo2max_est`), via two independent, published,
// non-proprietary relationships (textbook exercise physiology, not any vendor's formula):
//
//   1. ACSM running-economy equation: VO2 (ml/kg/min) ≈ 0.2 × speed(m/min) + 3.5
//      (American College of Sports Medicine metabolic calculation for running; public domain).
//   2. Percent-of-VO2max sustainable for a race distance — longer races sustain a lower fraction.
//      Widely cited approximate values (various sports-science sources converge near these), NOT a
//      single named model's output.
//
// APPROXIMATE, not a measurement or a guarantee — two independent published relationships chained
// together compound their own looseness, and race performance also depends on pacing, terrain,
// weather, and fueling this can't see. Framed as "estimated," same honesty bar as FitnessAgeEngine's
// own vo2max estimate it builds on.
public enum RaceTimePredictor {

    /// ACSM running-economy equation coefficients (public domain).
    static let acsmSlope = 0.2        // ml/kg/min per (m/min)
    static let acsmIntercept = 3.5    // ml/kg/min at zero speed (resting/baseline O2 cost)

    public struct Distance: Equatable, Sendable {
        public let label: String
        public let meters: Double
        /// Fraction of VO2max sustainable for the DURATION of this distance — shorter races sustain
        /// more of it. Not time-iterated (a simplification many public race calculators also make):
        /// tied to the standard distance rather than a predicted-time feedback loop.
        public let vo2maxFraction: Double
        public init(label: String, meters: Double, vo2maxFraction: Double) {
            self.label = label; self.meters = meters; self.vo2maxFraction = vo2maxFraction
        }
    }

    public static let standardDistances: [Distance] = [
        Distance(label: "5K", meters: 5_000, vo2maxFraction: 0.95),
        Distance(label: "10K", meters: 10_000, vo2maxFraction: 0.90),
        Distance(label: "Half Marathon", meters: 21_097, vo2maxFraction: 0.85),
        Distance(label: "Marathon", meters: 42_195, vo2maxFraction: 0.75),
    ]

    public struct Estimate: Equatable, Sendable {
        public let distance: Distance
        /// Predicted finish time, seconds.
        public let seconds: Double
        public init(distance: Distance, seconds: Double) {
            self.distance = distance; self.seconds = seconds
        }
    }

    /// `vo2max`: ml/kg/min (`FitnessAgeEngine.estimateVO2max` / the stored `vo2max_est` series' latest
    /// value). Returns nil for a distance whose implied race speed would be non-positive (a VO2max too
    /// low for the ACSM intercept at that sustained fraction — an honest "can't estimate this one"
    /// rather than a nonsense negative/infinite time).
    public static func estimate(vo2max: Double, distances: [Distance] = standardDistances) -> [Estimate] {
        distances.compactMap { d in
            let vo2AtRace = vo2max * d.vo2maxFraction
            let speedMPerMin = (vo2AtRace - acsmIntercept) / acsmSlope
            guard speedMPerMin > 0 else { return nil }
            let minutes = d.meters / speedMPerMin
            return Estimate(distance: d, seconds: minutes * 60)
        }
    }

    /// `HH:MM:SS` (or `MM:SS` under an hour), for a caller that wants plain text without pulling in
    /// DateComponentsFormatter state.
    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
