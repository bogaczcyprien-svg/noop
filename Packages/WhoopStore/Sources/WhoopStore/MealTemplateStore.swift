import Foundation
import GRDB

// MARK: - v49 store: saved meal templates ("favorites") for one-tap re-logging
//
// FORK-ONLY, not ported to Android. Mirrors `LiftExerciseRow`'s natural-key upsert idiom precisely
// (`LiftLogStore.swift`): the natural key is (deviceId, name), re-saving an existing name updates it
// rather than duplicating, and `lastUsedTs` (bumped on every quick-add tap via `touchMealTemplate`)
// drives most-recently-used-first ordering. Logging FROM a template still goes through `MealLogStore`
// (a template is a reusable macro bundle, not a log entry itself).
public struct MealTemplateRow: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var deviceId: String
    /// Natural key is (deviceId, name) — exactly as the user typed it when saving the template.
    public var name: String
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    /// Unix seconds.
    public var createdAt: Int
    /// Unix seconds; bumped on every quick-add tap. Nil until first used.
    public var lastUsedTs: Int?

    public init(
        id: String,
        deviceId: String,
        name: String,
        proteinG: Double,
        carbsG: Double,
        fatG: Double,
        createdAt: Int,
        lastUsedTs: Int?
    ) {
        self.id = id
        self.deviceId = deviceId
        self.name = name
        self.proteinG = proteinG
        self.carbsG = carbsG
        self.fatG = fatG
        self.createdAt = createdAt
        self.lastUsedTs = lastUsedTs
    }

    static func decode(_ row: Row) -> MealTemplateRow {
        MealTemplateRow(
            id: row["id"],
            deviceId: row["deviceId"],
            name: row["name"],
            proteinG: row["proteinG"],
            carbsG: row["carbsG"],
            fatG: row["fatG"],
            createdAt: row["createdAt"],
            lastUsedTs: row["lastUsedTs"]
        )
    }
}

extension WhoopStore {

    /// Upsert templates by natural key (deviceId, name): re-saving an existing name overwrites its
    /// macros rather than creating a duplicate, same conflict shape as `upsertLiftExercises`.
    @discardableResult
    public func upsertMealTemplates(_ rows: [MealTemplateRow]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        return try syncWrite { db in
            var n = 0
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO mealTemplate
                        (id, deviceId, name, proteinG, carbsG, fatG, createdAt, lastUsedTs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(deviceId, name) DO UPDATE SET
                        proteinG = excluded.proteinG,
                        carbsG = excluded.carbsG,
                        fatG = excluded.fatG,
                        lastUsedTs = MAX(COALESCE(excluded.lastUsedTs, 0), COALESCE(lastUsedTs, 0))
                    """, arguments: [
                        r.id, r.deviceId, r.name, r.proteinG, r.carbsG, r.fatG, r.createdAt, r.lastUsedTs,
                    ])
                n += db.changesCount
            }
            return n
        }
    }

    /// The device's saved templates, most-recently-used first, alphabetical within each — the
    /// quick-add row's whole ordering.
    public func mealTemplates(deviceId: String) async throws -> [MealTemplateRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM mealTemplate
                WHERE deviceId = ?
                ORDER BY COALESCE(lastUsedTs, 0) DESC, name ASC
                """, arguments: [deviceId]).map(MealTemplateRow.decode)
        }
    }

    /// Bump a template's `lastUsedTs` to `now` — called every time it is quick-added, so the row
    /// floats to the top of the picker the way `liftExercises`' ordering already works.
    @discardableResult
    public func touchMealTemplate(id: String, now: Int) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "UPDATE mealTemplate SET lastUsedTs = ? WHERE id = ?", arguments: [now, id])
            return db.changesCount > 0
        }
    }

    /// Delete one saved template. Meals already logged from it are untouched — they carry their own
    /// copy of the macros, same as a deleted lift exercise leaves its logged sets alone.
    @discardableResult
    public func deleteMealTemplate(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM mealTemplate WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }
}
