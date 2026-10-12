import Foundation

// WorkoutCarbRefuel.swift — FORK-ONLY, not ported to Android. Post-workout carbohydrate-timing
// guidance, shown alongside `SubstrateEstimator`'s fuel-source split in the workout detail.
//
// Two deliberately SEPARATE numbers, never one derived from the other:
//   - `carbsBurnedG`: context only — this session's estimated carbohydrate burn, from
//     `SubstrateEstimator.SubstrateEstimate.carbKcal / 4`. What the session cost.
//   - `refuelTargetG`: the actual recommendation — standard post-exercise carbohydrate-replacement
//     guidance (ISSN position stand, Kerksick et al. 2017/Jäger et al. 2017): ~1.0 g carbs/kg
//     bodyweight/hour for the first few hours after a substantial endurance/high-intensity session,
//     capped at 4 hours here. This is WEIGHT + DURATION based, not a reflection of calories burned —
//     glycogen replacement targets are set by body mass and time, not by this one estimate of what was
//     oxidized. Conflating the two would overstate precision this app does not have.
public struct WorkoutCarbRefuel: Equatable, Sendable {
    /// This session's estimated carbohydrate burn (context only) — `SubstrateEstimate.carbKcal / 4`.
    public let carbsBurnedG: Double
    /// The recommended carbohydrate replacement target, in grams.
    public let refuelTargetG: Double
    /// The refueling window this target assumes, in hours (`min(durationHours, 4)`).
    public let windowHours: Double

    public init(carbsBurnedG: Double, refuelTargetG: Double, windowHours: Double) {
        self.carbsBurnedG = carbsBurnedG
        self.refuelTargetG = refuelTargetG
        self.windowHours = windowHours
    }
}

public enum WorkoutCarbRefuelEstimator {

    /// ISSN post-exercise carbohydrate-replacement guidance: grams of carbs per kg bodyweight per hour,
    /// for the recovery window below.
    public static let gPerKgPerHour = 1.0
    /// The guidance's own window — further hours don't add more at this rate.
    public static let maxWindowHours = 4.0
    /// Below this duration AND this estimated carb burn, a session is unlikely to have meaningfully
    /// depleted glycogen — recommending a refuel target would overstate what a short/light session
    /// actually costs.
    public static let minDurationMin = 45.0
    public static let minCarbKcal = 150.0
    /// Targets round to the nearest multiple of this (g), same "round for display" convention as
    /// `MacroTargets.roundToG`.
    public static let roundToG = 5.0

    /// - Parameters:
    ///   - substrate: this session's fuel-source split (`SubstrateEstimator.estimate(...)`).
    ///   - weightKg: the profile's body weight — the refuel target scales directly off it.
    ///   - durationS: the session's duration, in seconds.
    /// - Returns: nil when the session doesn't clear the "substantial enough" gate, or `weightKg` is
    ///   non-positive (a refuel target can't scale off no weight) — never a fabricated recommendation.
    public static func estimate(substrate: SubstrateEstimator.SubstrateEstimate,
                                weightKg: Double, durationS: Double) -> WorkoutCarbRefuel? {
        guard weightKg > 0,
              durationS / 60.0 >= minDurationMin || substrate.carbKcal >= minCarbKcal else { return nil }
        let hours = min(durationS / 3600.0, maxWindowHours)
        let target = roundToNearest(weightKg * gPerKgPerHour * hours, step: roundToG)
        return WorkoutCarbRefuel(carbsBurnedG: substrate.carbKcal / 4.0, refuelTargetG: target, windowHours: hours)
    }

    /// Round `value` to the nearest multiple of `step` (step > 0), half rounds up — the Double twin of
    /// `MacroTargets.roundToNearest`, duplicated locally rather than imported for the same reason that
    /// one is: independent, swappable formulas.
    static func roundToNearest(_ value: Double, step: Double) -> Double {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }
}
