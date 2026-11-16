import Foundation

// DayEnergyProjection.swift — FORK-ONLY, not ported to Android. The whole day's expected energy, for the
// Nutrition tab's "left to eat today". The on-device estimate (`DailyMetric.activeKcalEst`) only covers
// the hours already lived, so at 9 am it reads a few hundred kcal. This projects the rest of the day at
// the user's own base-day rate (their quiet office day, 2300 kcal by default) and never goes below that
// base day: a workout raises the target as soon as it is in the estimate, a quiet day stays at the base.
public enum DayEnergyProjection {

    /// The user's reference for a day with no sport (kcal), until they set their own.
    public static let defaultBaseDayKcal: Double = 2300
    /// Allowed range for the base day setting.
    public static let baseDayRange: ClosedRange<Double> = 1200...4500

    /// `max(base, burnedSoFar + secondsLeft x base / 86 400)`. A nil or non-positive estimate (no heart rate
    /// yet today) gives the base day. `secondsLeftInDay` is clamped to 0...86 400.
    public static func projectedDayKcal(burnedSoFarKcal: Double?, baseDayKcal: Double,
                                        secondsLeftInDay: Double) -> Double {
        let base = min(max(baseDayKcal, baseDayRange.lowerBound), baseDayRange.upperBound)
        guard let burned = burnedSoFarKcal, burned.isFinite, burned > 0 else { return base }
        let left = min(max(secondsLeftInDay, 0), 86_400)
        return max(base, burned + left * base / 86_400)
    }
}
