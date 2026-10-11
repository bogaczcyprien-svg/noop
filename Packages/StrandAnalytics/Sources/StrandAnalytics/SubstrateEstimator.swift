import Foundation
import WhoopProtocol

// SubstrateEstimator.swift — FORK-ONLY, not ported to Android. Approximate fat-vs-carbohydrate energy
// split for one workout bout, from heart rate alone.
//
// APPROXIMATE — NOT laboratory calorimetry (indirect calorimetry / RER from expired-gas analysis), NOT
// a VO2max test, NOT clinical/cloud parity. Same honesty bar as `Calories.swift`'s HR-based estimates:
// this is what a wearable can infer from HR alone, offered as a directional guide, never a lab result.
//
// Model: the "crossover concept" (Brooks & Mercier 1994, J Appl Physiol) — fat oxidation dominates at
// low intensity, a crossover to carbohydrate-dominant metabolism occurs as intensity rises, matching the
// simplified intensity-vs-substrate curves in Achten & Jeukendrup 2004 (Sports Med). Expressed here as a
// piecewise-linear interpolation over mean Karvonen %HRR (StrainScorer.pctHRR) rather than %VO2max/RER —
// %HRR is what a wearable can actually measure; this is a deliberately coarse wearable-appropriate
// simplification of a continuous physiological curve, not a personalized lab-fitted one.
public enum SubstrateEstimator {

    /// `(hrrPct, fatPct)` control points the curve interpolates between, clamped at the ends. Fat
    /// dominates through light aerobic work (a "Fatmax plateau" through ~40% HRR), falls off through
    /// moderate effort, and crosses over to carbohydrate-dominant above ~70-85% HRR, approaching
    /// near-exclusive carbohydrate/anaerobic glycolysis at maximal effort.
    static let controlPoints: [(hrrPct: Double, fatPct: Double)] = [
        (0, 70), (40, 70), (55, 55), (70, 35), (85, 15), (100, 5),
    ]

    /// Fat's share of energy (0...100) at a given mean %HRR, by linear interpolation between the
    /// bracketing control points above (clamped outside [0, 100]).
    public static func fatPercent(forMeanHRRPercent hrrPct: Double) -> Double {
        let x = min(100.0, max(0.0, hrrPct))
        guard x > controlPoints.first!.hrrPct else { return controlPoints.first!.fatPct }
        guard x < controlPoints.last!.hrrPct else { return controlPoints.last!.fatPct }
        for i in 1..<controlPoints.count {
            let (x1, y1) = controlPoints[i - 1]
            let (x2, y2) = controlPoints[i]
            if x <= x2 {
                guard x2 > x1 else { return y2 }
                let frac = (x - x1) / (x2 - x1)
                return y1 + frac * (y2 - y1)
            }
        }
        return controlPoints.last!.fatPct
    }

    /// One bout's estimated fat/carbohydrate energy split.
    public struct SubstrateEstimate: Equatable, Sendable {
        /// Duration-weighted mean Karvonen %HRR over the bout (0...100), the value the split was read
        /// off the curve at.
        public let meanHRRPct: Double
        /// Fat's share of energy burned (0...100). `carbPct` is always `100 - fatPct`.
        public let fatPct: Double
        public let carbPct: Double
        /// `totalKcal` split by the two percentages above.
        public let fatKcal: Double
        public let carbKcal: Double

        public init(meanHRRPct: Double, fatPct: Double, carbPct: Double, fatKcal: Double, carbKcal: Double) {
            self.meanHRRPct = meanHRRPct; self.fatPct = fatPct; self.carbPct = carbPct
            self.fatKcal = fatKcal; self.carbKcal = carbKcal
        }
    }

    /// Estimate the fat/carbohydrate split of `totalKcal` already attributed to this bout (e.g. a
    /// workout's own `WorkoutRow.energyKcal`, from `Calories.estimateBoutCalories` or an imported
    /// value) — this function never recomputes calories itself, only splits an already-trusted total.
    ///
    /// - Parameters:
    ///   - hr: the bout's heart-rate samples, any order, any cadence.
    ///   - restingHR: the day's resting HR (bpm), the Karvonen reserve's floor.
    ///   - maxHR: the effective HRmax (bpm), the Karvonen reserve's ceiling.
    ///   - totalKcal: the bout's already-estimated total energy (kcal) to split.
    /// - Returns: nil when there is no HR, `maxHR` isn't usably above `restingHR` (a degenerate reserve
    ///   would make every %HRR reading meaningless), or `totalKcal` is non-positive — never a fabricated
    ///   split.
    ///
    /// Each sample is weighted by the ELAPSED time to the next sample, capped at
    /// `WorkoutDetector.mergeGapS` — the same shape `Calories.estimateBoutCalories` already uses so a
    /// sparse, non-1Hz stream is weighted by real seconds rather than by sample count, and one isolated
    /// reading after a dropout can't dominate the mean.
    public static func estimate(hr: [HRSample], restingHR: Double, maxHR: Double,
                                totalKcal: Double) -> SubstrateEstimate? {
        guard !hr.isEmpty, maxHR > restingHR, totalKcal > 0 else { return nil }
        let hrReserve = maxHR - restingHR

        let ordered = hr.sorted { $0.ts < $1.ts }
        var weightedPctSum = 0.0
        var weightSum = 0.0
        for i in ordered.indices {
            let pct = StrainScorer.pctHRR(Double(ordered[i].bpm), restingHR: restingHR, hrReserve: hrReserve)
            let dur: Double
            if i < ordered.count - 1 {
                let gap = Double(ordered[i + 1].ts - ordered[i].ts)
                dur = gap > 0 ? min(gap, WorkoutDetector.mergeGapS) : 1.0
            } else {
                dur = 1.0
            }
            weightedPctSum += pct * dur
            weightSum += dur
        }
        guard weightSum > 0 else { return nil }
        let meanHRRPct = weightedPctSum / weightSum

        let fatPct = fatPercent(forMeanHRRPercent: meanHRRPct)
        let carbPct = 100.0 - fatPct
        return SubstrateEstimate(
            meanHRRPct: meanHRRPct, fatPct: fatPct, carbPct: carbPct,
            fatKcal: totalKcal * fatPct / 100.0, carbKcal: totalKcal * carbPct / 100.0)
    }
}
