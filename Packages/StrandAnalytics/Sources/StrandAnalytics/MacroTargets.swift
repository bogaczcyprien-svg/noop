import Foundation

// MacroTargets.swift — FORK-ONLY, not ported to Android. Pure daily macro-nutrient target math for the
// opt-in manual meal logger (Nutrition tab). Mirrors HydrationGoal.swift's shape: a baseline-per-kg
// scaled by a small bump off the day's Effort/strain, rounded for a clean read-out — but unlike
// Hydration, protein/carbs ALSO need body weight (not just sex), and fat is derived as the energy
// remainder after protein+carbs, floored so it never bottoms out on a high-protein/high-carb day.
//
// This is a personal, approximate guide — NOT medical/dietetic advice, NOT athlete-specific lab-tested
// targets. Grounded in two widely-cited sports-nutrition position stands, not invented:
//   protein 1.6-2.2 g/kg/day: ISSN position stand (Jäger et al. 2017, J Int Soc Sports Nutr) — the
//     cited range for resistance/endurance athletes; 1.6 is the low end for a rest day, 2.2 the high
//     end for a maximal-effort day.
//   carbs 3-8 g/kg/day: the "train-low/train-high" carbohydrate periodization literature (Burke et al.
//     2011) — ~3 g/kg for a light/rest day, up to 8 g/kg for a high-volume/high-intensity day (short of
//     the 10-12 g/kg reserved for multi-hour endurance events, deliberately not reached here since NOOP
//     has no event-duration input to scale against).
// `effort` is the day's Effort/strain score on NOOP's native 0...100 scale (`DailyMetric.strain`), same
// input HydrationGoal.effortBump already uses. `effort == nil` (no Effort yet today) falls back to the
// rest-day baseline (0% scaling) — never a fabricated bump, same convention as Hydration.
public enum MacroTargets {

    // MARK: - Constants

    /// Protein g/kg/day at Effort 0 (rest day) and the additional g/kg/day reached at Effort 100.
    public static let proteinBaselineGPerKg = 1.6
    public static let proteinEffortRangeGPerKg = 0.6   // 1.6 -> 2.2 g/kg

    /// Carb g/kg/day at Effort 0 (rest day) and the additional g/kg/day reached at Effort 100.
    public static let carbBaselineGPerKg = 3.0
    public static let carbEffortRangeGPerKg = 5.0      // 3.0 -> 8.0 g/kg

    /// Fallback daily energy (kcal/kg/day) used only when no real day-energy estimate exists yet
    /// (`DailyMetric.activeKcalEst` nil — no HR today). ~30 kcal/kg/day is the common sedentary-to
    /// -moderately-active maintenance rule of thumb; it is a placeholder until a real estimate exists,
    /// not a claim of precision.
    public static let fallbackKcalPerKg = 30.0

    /// Fat must cover at least this fraction of total daily energy, even on a day where the protein +
    /// carb targets already consume nearly the whole energy budget (ACSM/ISSN caution against very-low
    /// -fat athletic diets: essential fatty acids, fat-soluble vitamin absorption, hormonal health).
    public static let fatFloorFraction = 0.20

    /// kcal per gram, the standard Atwater factors for protein/carbohydrate and fat.
    public static let kcalPerGProtein = 4.0
    public static let kcalPerGCarb = 4.0
    public static let kcalPerGFat = 9.0

    /// Targets round to the nearest multiple of this (g) for a clean read-out, matching HydrationGoal's
    /// "round for display, don't pretend to that precision" convention.
    public static let roundToG = 5

    // MARK: - Pieces (each pure + independently testable, mirroring HydrationGoal's shape)

    /// Protein g/kg/day for a day's Effort score: `1.6 + clamp(effort,0...100)/100 * 0.6`. `effort ==
    /// nil` (no Effort yet) yields the rest-day baseline (1.6), never a fabricated bump.
    public static func proteinGPerKg(effort: Double?) -> Double {
        proteinBaselineGPerKg + effortFraction(effort) * proteinEffortRangeGPerKg
    }

    /// Carb g/kg/day for a day's Effort score: `3.0 + clamp(effort,0...100)/100 * 5.0`. Same nil
    /// handling as `proteinGPerKg`.
    public static func carbGPerKg(effort: Double?) -> Double {
        carbBaselineGPerKg + effortFraction(effort) * carbEffortRangeGPerKg
    }

    /// `clamp(effort, 0...100) / 100`, or 0 when `effort` is nil/non-finite. Shared by both per-kg
    /// functions so they can never disagree on how Effort is read.
    private static func effortFraction(_ effort: Double?) -> Double {
        guard let effort, effort.isFinite else { return 0 }
        return min(100.0, max(0.0, effort)) / 100.0
    }

    /// Round `value` to the nearest multiple of `step` (step > 0), half rounds up — matching
    /// `HydrationGoal.roundToNearest`'s rule. Duplicated locally (2 lines) rather than imported: the two
    /// trackers are meant to be independent, swappable formulas, the same reasoning HydrationGoal itself
    /// doesn't import anything.
    public static func roundToNearest(_ value: Int, step: Int) -> Int {
        guard step > 0 else { return value }
        return ((value + step / 2) / step) * step
    }

    /// Calories from a macro split, the standard Atwater factors (4/4/9 kcal/g). Shared by the daily
    /// -target math below and the meal-logging save path, so the conversion lives in exactly one place.
    public static func kcal(proteinG: Double, carbsG: Double, fatG: Double) -> Double {
        proteinG * kcalPerGProtein + carbsG * kcalPerGCarb + fatG * kcalPerGFat
    }

    // MARK: - Daily targets

    /// One day's macro targets, in grams, rounded to `roundToG`.
    public struct MacroTargetGrams: Equatable, Sendable {
        public let proteinG: Int
        public let carbsG: Int
        public let fatG: Int
        public init(proteinG: Int, carbsG: Int, fatG: Int) {
            self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        }
        /// Total energy the three targets represent (Atwater factors), for display alongside the grams.
        public var totalKcal: Int {
            Int(MacroTargets.kcal(proteinG: Double(proteinG), carbsG: Double(carbsG),
                                  fatG: Double(fatG)).rounded())
        }
    }

    /// The day's protein/carb/fat targets in grams.
    ///
    /// - Parameters:
    ///   - weightKg: the profile's body weight. Protein and carb targets scale directly off it; a
    ///     non-positive weight is treated as unusable and yields 0g for both (fat still floors against
    ///     `dailyEnergyKcal`/the energy fallback, since the floor is energy-based, not weight-based).
    ///   - effort: today's Effort/strain (0...100), or nil before it exists. Drives both protein's and
    ///     carb's per-kg rate — a harder day raises both targets together.
    ///   - dailyEnergyKcal: today's total (resting + active) energy estimate — pass
    ///     `DailyMetric.activeKcalEst` (already resting+active combined, see `Calories.estimateDayEnergy`).
    ///     nil falls back to `weightKg * fallbackKcalPerKg` until a real HR-based estimate exists for the
    ///     day.
    /// - Returns: protein/carb targets from the per-kg rates above; fat as the energy remainder after
    ///   protein+carbs, floored at `fatFloorFraction` of total energy so it never bottoms out.
    public static func dailyTargets(weightKg: Double, effort: Double?,
                                    dailyEnergyKcal: Double?) -> MacroTargetGrams {
        guard weightKg > 0 else {
            // No usable weight: protein/carbs can't scale off it. Fat still has an energy-based floor
            // when an energy figure exists, so the day isn't a bare zero across the board.
            let totalEnergy = dailyEnergyKcal ?? 0
            let fatG = totalEnergy > 0
                ? roundToNearest(Int((totalEnergy * fatFloorFraction / kcalPerGFat).rounded()), step: roundToG)
                : 0
            return MacroTargetGrams(proteinG: 0, carbsG: 0, fatG: fatG)
        }

        let proteinGRaw = weightKg * proteinGPerKg(effort: effort)
        let carbsGRaw = weightKg * carbGPerKg(effort: effort)
        let proteinG = roundToNearest(Int(proteinGRaw.rounded()), step: roundToG)
        let carbsG = roundToNearest(Int(carbsGRaw.rounded()), step: roundToG)

        let proteinKcal = Double(proteinG) * kcalPerGProtein
        let carbKcal = Double(carbsG) * kcalPerGCarb
        let totalEnergyKcal = dailyEnergyKcal ?? (weightKg * fallbackKcalPerKg)

        let remainderKcal = max(0.0, totalEnergyKcal - proteinKcal - carbKcal)
        let fatFloorKcal = totalEnergyKcal * fatFloorFraction
        let fatGRaw = max(remainderKcal, fatFloorKcal) / kcalPerGFat
        let fatG = roundToNearest(Int(fatGRaw.rounded()), step: roundToG)

        return MacroTargetGrams(proteinG: proteinG, carbsG: carbsG, fatG: fatG)
    }
}
