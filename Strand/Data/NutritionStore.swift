import Foundation
import WhoopStore
import StrandAnalytics

// MARK: - Nutrition tracker (FORK-ONLY, not ported to Android) — opt-in manual meal logging
//
// Mirrors HydrationStore's shape: a dedicated, strap-independent source id (meals aren't tied to
// whichever WHOOP is active) and a thin Repository extension wrapping the WhoopStore CRUD
// (`MealLogStore.swift`, v48-meal-log). Unlike Hydration, there is no quick-tap amount and no
// imported-source merge — the user types exact grams per meal, and that IS the source of truth, so
// there is nothing to rebank from a UserDefaults entry list; `meal` rows ARE the detail.
enum NutritionStore {
    /// Source/device id meal rows are written under — its own local-only source, independent of
    /// whichever strap is active (eating isn't tied to a device). MUST match the "macro-manual"
    /// metricSeries source id the Explorer/Compare rebank below writes under.
    static let sourceId = "meal-log"

    /// metricSeries source id for the day-sum rebank (distinct from the existing CSV importer's
    /// "nutrition-csv", same distinguishing idea as Hydration's "hydration" vs "hydrationImported").
    static let metricSeriesSourceId = "macro-manual"
}

extension Repository {

    /// Local "yyyy-MM-dd" parser, self-contained rather than reaching for `Repository`'s own (file
    /// -private) day formatters — this file only needs the reverse (key -> Date) direction.
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// `[start, end)` unix-second bounds of the local calendar day `dayKey` falls on (`yyyy-MM-dd`).
    private static func localDayBounds(_ dayKey: String) -> (start: Int, end: Int) {
        let cal = Calendar.current
        let date = dayKeyParser.date(from: dayKey) ?? Date()
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970))
    }

    /// Today's (or `day`'s) logged meals, oldest first.
    func meals(day: String? = nil) async -> [MealRow] {
        guard let store = await storeHandle() else { return [] }
        let dayKey = day ?? Repository.localDayKey(Date())
        let (start, end) = Self.localDayBounds(dayKey)
        return (try? await store.meals(deviceId: NutritionStore.sourceId, fromTs: start, toTs: end - 1)) ?? []
    }

    /// Save a meal (new or edited — `id` identifies which). Computes `caloriesKcal` from the grams via
    /// `MacroTargets.kcal` (the shared 4/4/9 Atwater conversion) so the store never has to. Rebanks the
    /// day's totals into `metricSeries` afterward so Explorer/Compare stay current.
    @discardableResult
    func saveMeal(id: String = UUID().uuidString, loggedAt: Int, name: String?,
                 proteinG: Double, carbsG: Double, fatG: Double, note: String? = nil) async -> MealRow {
        let row = MealRow(id: id, deviceId: NutritionStore.sourceId, loggedAt: loggedAt, name: name,
                          proteinG: proteinG, carbsG: carbsG, fatG: fatG,
                          caloriesKcal: MacroTargets.kcal(proteinG: proteinG, carbsG: carbsG, fatG: fatG),
                          note: note)
        if let store = await storeHandle() {
            _ = try? await store.upsertMeals([row])
        }
        await rebankMacroTotals(day: Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(loggedAt))))
        return row
    }

    /// Delete a logged meal, then rebank the affected day's totals.
    @discardableResult
    func deleteMeal(id: String, day: String? = nil) async -> Bool {
        guard let store = await storeHandle() else { return false }
        let removed = (try? await store.deleteMeal(id: id)) ?? false
        if removed {
            await rebankMacroTotals(day: day ?? Repository.localDayKey(Date()))
        }
        return removed
    }

    /// Re-sum `day`'s logged meals into `metricSeries` under the "macro-manual" source (calories_in /
    /// protein_g / carbs_g / fat_g), mirroring `HydrationStore`'s rebank-after-write idiom, so the
    /// Explorer/Compare screens see the same totals the Nutrition tab shows.
    private func rebankMacroTotals(day: String) async {
        guard let store = await storeHandle() else { return }
        let rows = await meals(day: day)
        let totals: [(key: String, value: Double)] = [
            ("calories_in", rows.reduce(0) { $0 + $1.caloriesKcal }),
            ("protein_g", rows.reduce(0) { $0 + $1.proteinG }),
            ("carbs_g", rows.reduce(0) { $0 + $1.carbsG }),
            ("fat_g", rows.reduce(0) { $0 + $1.fatG }),
        ]
        let points = totals.map { MetricPoint(day: day, key: $0.key, value: $0.value) }
        _ = try? await store.upsertMetricSeries(points, deviceId: NutritionStore.metricSeriesSourceId)
    }

    /// Today's macro targets, from the profile's weight + today's Effort/strain + today's (resting +
    /// active) energy estimate. Pure math in `MacroTargets`; this just feeds it the live inputs.
    func macroTargets(weightKg: Double) -> MacroTargets.MacroTargetGrams {
        MacroTargets.dailyTargets(weightKg: weightKg, effort: today?.strain,
                                  dailyEnergyKcal: today?.activeKcalEst)
    }
}
