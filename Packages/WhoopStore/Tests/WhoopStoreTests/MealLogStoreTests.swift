import XCTest
import GRDB
@testable import WhoopStore

/// FORK-ONLY, not ported to Android. Mirrors LiftLogStoreTests.swift's shape.
final class MealLogStoreTests: XCTestCase {

    // MARK: - v48 migration (additive: one new table + index, nothing dropped)

    func testV48CreatesMealTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("meal"), "missing table meal")
        let pk = try await store.primaryKeyColumns("meal")
        XCTAssertEqual(pk, ["id"], "meal primary key should be id")
    }

    func testV48ColumnsArePresent() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "meal")
        for c in ["id", "deviceId", "loggedAt", "name", "proteinG", "carbsG", "fatG",
                  "caloriesKcal", "note"] {
            XCTAssertTrue(columns.contains(c), "meal missing column \(c)")
        }
    }

    func testV48CreatesIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let indexes = try await store.indexNamesForTest(table: "meal")
        XCTAssertTrue(indexes.contains("idx_meal_device_loggedAt"))
    }

    /// Additive: v48 must not drop any table that existed before it.
    func testV48IsAdditive() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in ["device", "hrSample", "workout", "dailyMetric", "liftExercise", "liftSession"] {
            XCTAssertTrue(tables.contains(t), "v48 must not drop \(t)")
        }
    }

    // MARK: - CRUD round-trip

    private func row(id: String = UUID().uuidString, loggedAt: Int = 1_700_000_000,
                     name: String? = "Breakfast", proteinG: Double = 30, carbsG: Double = 60,
                     fatG: Double = 15, caloriesKcal: Double = 615, note: String? = nil) -> MealRow {
        MealRow(id: id, deviceId: "dev", loggedAt: loggedAt, name: name, proteinG: proteinG,
               carbsG: carbsG, fatG: fatG, caloriesKcal: caloriesKcal, note: note)
    }

    func testUpsertMealsIsIdempotentById() async throws {
        let store = try await WhoopStore.inMemory()
        let id = UUID().uuidString
        _ = try await store.upsertMeals([row(id: id, proteinG: 30)])
        var edited = row(id: id, proteinG: 45)
        edited.name = "Lunch"
        _ = try await store.upsertMeals([edited])

        let back = try await store.meals(deviceId: "dev", fromTs: 0, toTs: Int.max)
        XCTAssertEqual(back.count, 1, "re-saving the same id must update in place, not duplicate")
        XCTAssertEqual(back[0].proteinG, 45)
        XCTAssertEqual(back[0].name, "Lunch")
    }

    func testMealsRangeReadOrdersByLoggedAtAscending() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMeals([
            row(loggedAt: 1_700_010_000, name: "Dinner"),
            row(loggedAt: 1_700_000_000, name: "Breakfast"),
            row(loggedAt: 1_700_005_000, name: "Lunch"),
        ])

        let back = try await store.meals(deviceId: "dev", fromTs: 1_700_000_000, toTs: 1_700_010_000)
        XCTAssertEqual(back.map(\.name), ["Breakfast", "Lunch", "Dinner"])
    }

    func testMealsRangeReadExcludesOutOfWindowEntries() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMeals([
            row(loggedAt: 1_699_999_999, name: "Yesterday"),
            row(loggedAt: 1_700_005_000, name: "Today"),
            row(loggedAt: 1_700_100_000, name: "Tomorrow"),
        ])

        let back = try await store.meals(deviceId: "dev", fromTs: 1_700_000_000, toTs: 1_700_010_000)
        XCTAssertEqual(back.map(\.name), ["Today"])
    }

    func testDeleteMealRemovesRow() async throws {
        let store = try await WhoopStore.inMemory()
        let id = UUID().uuidString
        _ = try await store.upsertMeals([row(id: id)])
        let removed = try await store.deleteMeal(id: id)
        XCTAssertTrue(removed)

        let back = try await store.meals(deviceId: "dev", fromTs: 0, toTs: Int.max)
        XCTAssertTrue(back.isEmpty)
    }

    func testDeleteMealReturnsFalseWhenNothingMatched() async throws {
        let store = try await WhoopStore.inMemory()
        let removed = try await store.deleteMeal(id: "does-not-exist")
        XCTAssertFalse(removed)
    }

    func testCaloriesKcalIsStoredVerbatimNotRecomputed() async throws {
        // The store never recomputes caloriesKcal from the macro grams — it stores whatever the
        // caller (MacroTargets.kcal) handed it, even a deliberately "wrong" figure, so a later change
        // to the kcal-per-gram convention never silently rewrites history.
        let store = try await WhoopStore.inMemory()
        let id = UUID().uuidString
        _ = try await store.upsertMeals([row(id: id, proteinG: 30, carbsG: 60, fatG: 15, caloriesKcal: 1.0)])

        let back = try await store.meals(deviceId: "dev", fromTs: 0, toTs: Int.max)
        XCTAssertEqual(back.first?.caloriesKcal, 1.0)
    }

    func testOptionalNameAndNoteRoundTripAsNil() async throws {
        let store = try await WhoopStore.inMemory()
        let id = UUID().uuidString
        _ = try await store.upsertMeals([row(id: id, name: nil, note: nil)])

        let back = try await store.meals(deviceId: "dev", fromTs: 0, toTs: Int.max).first
        XCTAssertNil(back?.name)
        XCTAssertNil(back?.note)
    }

    func testMealsAreScopedByDeviceId() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertMeals([row(id: UUID().uuidString)])
        var other = row(id: UUID().uuidString)
        other.deviceId = "other-device"
        _ = try await store.upsertMeals([other])

        let back = try await store.meals(deviceId: "dev", fromTs: 0, toTs: Int.max)
        XCTAssertEqual(back.count, 1)
    }
}
