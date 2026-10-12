import XCTest
import GRDB
@testable import WhoopStore

/// FORK-ONLY, not ported to Android. Mirrors MealLogStoreTests.swift's shape, plus the natural-key
/// upsert tests from LiftExerciseRow (the idiom this table's conflict target copies).
final class MealTemplateStoreTests: XCTestCase {

    // MARK: - v49 migration (additive: one new table + unique index, nothing dropped)

    func testV49CreatesMealTemplateTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("mealTemplate"), "missing table mealTemplate")
        let pk = try await store.primaryKeyColumns("mealTemplate")
        XCTAssertEqual(pk, ["id"], "mealTemplate primary key should be id")
    }

    func testV49ColumnsArePresent() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "mealTemplate")
        for c in ["id", "deviceId", "name", "proteinG", "carbsG", "fatG", "createdAt", "lastUsedTs"] {
            XCTAssertTrue(columns.contains(c), "mealTemplate missing column \(c)")
        }
    }

    func testV49CreatesUniqueNaturalKeyIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let indexes = try await store.indexNamesForTest(table: "mealTemplate")
        XCTAssertTrue(indexes.contains("idx_mealTemplate_natural"))
    }

    /// Additive: v49 must not drop any table that existed before it.
    func testV49IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "workout", "dailyMetric", "liftExercise", "meal"] {
            XCTAssertTrue(tables.contains(t), "v49 must not drop \(t)")
        }
    }

    // MARK: - Natural-key upsert (deviceId, name) — overwrites, never duplicates

    private func row(id: String = UUID().uuidString, name: String = "Protein shake",
                     proteinG: Double = 30, carbsG: Double = 10, fatG: Double = 5,
                     createdAt: Int = 1_700_000_000, lastUsedTs: Int? = nil) -> MealTemplateRow {
        MealTemplateRow(id: id, deviceId: "dev", name: name, proteinG: proteinG, carbsG: carbsG,
                        fatG: fatG, createdAt: createdAt, lastUsedTs: lastUsedTs)
    }

    func testUpsertByNameOverwritesRatherThanDuplicating() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMealTemplates([row(name: "Protein shake", proteinG: 30)])
        _ = try await store.upsertMealTemplates([row(id: UUID().uuidString, name: "Protein shake", proteinG: 40)])

        let back = try await store.mealTemplates(deviceId: "dev")
        XCTAssertEqual(back.count, 1, "re-saving an existing NAME must update in place, not duplicate")
        XCTAssertEqual(back[0].proteinG, 40)
    }

    func testUpsertByNameKeepsHighestLastUsedTs() async throws {
        let store = try await WhoopStore.inMemory()
        let id = UUID().uuidString
        _ = try await store.upsertMealTemplates([row(id: id, name: "Oats", lastUsedTs: 1_700_000_500)])
        // A write with an OLDER (or nil) lastUsedTs must never regress the recency ordering.
        _ = try await store.upsertMealTemplates([row(id: id, name: "Oats", proteinG: 12, lastUsedTs: nil)])

        let back = try await store.mealTemplates(deviceId: "dev").first
        XCTAssertEqual(back?.proteinG, 12)
        XCTAssertEqual(back?.lastUsedTs, 1_700_000_500)
    }

    func testMealTemplatesOrderedByLastUsedThenName() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMealTemplates([
            row(name: "Never used", lastUsedTs: nil),
            row(name: "Used yesterday", lastUsedTs: 1_700_000_000),
            row(name: "Used today", lastUsedTs: 1_700_100_000),
        ])

        let back = try await store.mealTemplates(deviceId: "dev")
        XCTAssertEqual(back.map(\.name), ["Used today", "Used yesterday", "Never used"])
    }

    func testTouchMealTemplateBumpsLastUsedTs() async throws {
        let store = try await WhoopStore.inMemory()
        let id = UUID().uuidString
        _ = try await store.upsertMealTemplates([row(id: id, lastUsedTs: nil)])
        let touched = try await store.touchMealTemplate(id: id, now: 1_700_200_000)
        XCTAssertTrue(touched)

        let back = try await store.mealTemplates(deviceId: "dev").first
        XCTAssertEqual(back?.lastUsedTs, 1_700_200_000)
    }

    func testDeleteMealTemplateRemovesRow() async throws {
        let store = try await WhoopStore.inMemory()
        let id = UUID().uuidString
        _ = try await store.upsertMealTemplates([row(id: id)])
        let removed = try await store.deleteMealTemplate(id: id)
        XCTAssertTrue(removed)

        let back = try await store.mealTemplates(deviceId: "dev")
        XCTAssertTrue(back.isEmpty)
    }

    func testDeleteMealTemplateReturnsFalseWhenNothingMatched() async throws {
        let store = try await WhoopStore.inMemory()
        let removed = try await store.deleteMealTemplate(id: "does-not-exist")
        XCTAssertFalse(removed)
    }

    func testMealTemplatesAreScopedByDeviceId() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMealTemplates([row(id: UUID().uuidString, name: "Mine")])
        var other = row(id: UUID().uuidString, name: "Theirs")
        other.deviceId = "other-device"
        _ = try await store.upsertMealTemplates([other])

        let back = try await store.mealTemplates(deviceId: "dev")
        XCTAssertEqual(back.count, 1)
    }
}
