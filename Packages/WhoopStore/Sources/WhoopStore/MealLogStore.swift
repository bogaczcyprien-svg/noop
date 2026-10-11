import Foundation
import GRDB

// MARK: - v48 store: manual per-meal macro logging (Nutrition tab)
//
// FORK-ONLY, not ported to Android. Mirrors the LiftLogStore idiom precisely: a plain Codable row
// struct, raw `Row` fetch + manual decode, idempotent upsert keyed by `id`, all GRDB work through the
// actor's `syncWrite` / `syncRead` helpers.

/// One logged meal: carbs/protein/fat in grams, + an optional name. `caloriesKcal` is computed by the
/// CALLER at construction time (`MacroTargets.kcal`, the 4/4/9 Atwater factors) and carried verbatim —
/// this store never recomputes it, so a later change to the kcal-per-gram convention never rewrites
/// history.
public struct MealRow: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// Unix seconds — when the meal was logged/eaten.
    public var loggedAt: Int
    /// Optional, user-typed, verbatim.
    public var name: String?
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var caloriesKcal: Double
    public var note: String?

    public init(
        id: String,
        deviceId: String,
        loggedAt: Int,
        name: String?,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        caloriesKcal: Double,
        note: String?
    ) {
        self.id = id
        self.deviceId = deviceId
        self.loggedAt = loggedAt
        self.name = name
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.caloriesKcal = caloriesKcal
        self.note = note
    }

    static func decode(_ row: Row) -> MealRow {
        MealRow(
            id: row["id"],
            deviceId: row["deviceId"],
            loggedAt: row["loggedAt"],
            name: row["name"],
            proteinG: row["proteinG"],
            carbsG: row["carbsG"],
            fatG: row["fatG"],
            caloriesKcal: row["caloriesKcal"],
            note: row["note"]
        )
    }
}

extension WhoopStore {

    /// Upsert meals by `id`. Called when a meal is saved (new or edited) — the Nutrition tab's
    /// add/edit form always has a full row to write.
    @discardableResult
    public func upsertMeals(_ rows: [MealRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO meal
                        (id, deviceId, loggedAt, name, proteinG, carbsG, fatG, caloriesKcal, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        loggedAt = excluded.loggedAt,
                        name = excluded.name,
                        proteinG = excluded.proteinG,
                        carbsG = excluded.carbsG,
                        fatG = excluded.fatG,
                        caloriesKcal = excluded.caloriesKcal,
                        note = excluded.note
                    """, arguments: [
                        r.id, r.deviceId, r.loggedAt, r.name, r.proteinG, r.carbsG, r.fatG,
                        r.caloriesKcal, r.note,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// Meals for a device logged within `[fromTs, toTs]` inclusive, oldest first (the Nutrition tab's
    /// "today's meals" list reads in the order they were eaten).
    public func meals(deviceId: String, fromTs: Int, toTs: Int) async throws -> [MealRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM meal
                WHERE deviceId = ? AND loggedAt >= ? AND loggedAt <= ?
                ORDER BY loggedAt ASC
                """, arguments: [deviceId, fromTs, toTs]).map(MealRow.decode)
        }
    }

    /// Delete one logged meal. Returns true if a row was removed.
    @discardableResult
    public func deleteMeal(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM meal WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }
}
