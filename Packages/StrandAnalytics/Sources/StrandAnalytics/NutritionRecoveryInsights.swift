import Foundation

// MARK: - Nutrition -> next-day Recovery link (FORK-ONLY, not ported to Android)
//
// A thin, testable wrapper around `CorrelationEngine.lagged`, which already implements exactly what
// this needs ("correlate x[day] against y[day + lagDays]") but had no caller anywhere in the app. No
// new math — this just runs it once per nutrition series and ranks the results.

/// One nutrition metric's correlation with Recovery `lagDays` later (default: the next day).
public struct NutritionRecoveryInsight: Equatable, Sendable {
    /// "calories_in" | "protein_g" | "carbs_g" | "fat_g" | "balance_kcal" (caller-defined keys —
    /// this type does not care which strings are passed, it only ranks whatever it's given).
    public let metricKey: String
    public let correlation: Correlation

    public init(metricKey: String, correlation: Correlation) {
        self.metricKey = metricKey
        self.correlation = correlation
    }
}

public enum NutritionRecoveryInsights {

    /// Correlates each entry in `series` against `recovery`, shifted forward by `lagDays` (default 1 —
    /// "does what was eaten today predict tomorrow's recovery?"). Series with fewer than 3 lag-matched
    /// days, or zero variance, are silently omitted (same guard `CorrelationEngine.pearson` already
    /// applies) rather than reported as a spurious r. Strongest |r| first.
    public static func insights(series: [String: [(day: String, value: Double)]],
                                 recovery: [(day: String, value: Double)],
                                 lagDays: Int = 1) -> [NutritionRecoveryInsight] {
        series.compactMap { key, rows in
            CorrelationEngine.lagged(x: rows, y: recovery, lagDays: lagDays)
                .map { NutritionRecoveryInsight(metricKey: key, correlation: $0) }
        }
        .sorted { abs($0.correlation.r) > abs($1.correlation.r) }
    }
}
