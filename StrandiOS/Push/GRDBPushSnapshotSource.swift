import Foundation
import GRDB
import WhoopStore

/// Reads bounded snapshots straight off `WhoopStore`'s SQLite file for the push protocol.
///
/// Covers the full v1 registry, every column mapping checked against a migration in
/// `Packages/WhoopStore/Sources/WhoopStore/Database.swift`. One exception: `workout.routePolyline`
/// has no column in `WhoopStore` (Android-only field) — always sent as `null`, which the protocol
/// allows for a platform lacking that column.
public struct GRDBPushSnapshotSource: PushSnapshotSource {
    private let store: WhoopStore
    public static let supportedAppendTables: Set<PushAppendTable> = Set(PushAppendTable.allCases)
    public static let supportedMutableTables: Set<PushMutableTable> = Set(PushMutableTable.allCases)

    public init(store: WhoopStore) {
        self.store = store
    }

    public func knownDeviceIds(capabilities: PushCapabilities) async -> [String] {
        let writer = store.registryWriter
        return (try? await writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT deviceId FROM hrSample
                UNION SELECT DISTINCT deviceId FROM dailyMetric
                """)
        }) ?? []
    }

    public func appendRecord(table: PushAppendTable, deviceId: String, atRowId rowId: Int64) async throws -> PushAppendRecord? {
        let writer = store.registryWriter
        return try await writer.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT rowid, * FROM \(tableName(table)) WHERE deviceId = ? AND rowid = ?",
                arguments: [deviceId, rowId]
            ) else { return nil }
            return try decode(table, row: row)
        }
    }

    public func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] {
        let writer = store.registryWriter
        return try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT rowid, * FROM \(tableName(table)) WHERE deviceId = ? AND rowid > ? ORDER BY rowid ASC LIMIT ?",
                arguments: [deviceId, afterRowId, limit]
            )
            return try rows.map { try decode(table, row: $0) }
        }
    }

    public func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] {
        let writer = store.registryWriter
        switch table {
        case .dailyMetric:
            return try await writer.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM dailyMetric WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day ASC LIMIT ?",
                    arguments: [deviceId, window.fromDay, window.toDay, limit]
                )
                return rows.map(decodeDailyMetric)
            }
        case .sleepSession:
            return try await writer.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM sleepSession WHERE deviceId = ? AND startTs >= ? AND startTs < ? ORDER BY startTs ASC LIMIT ?",
                    arguments: [deviceId, window.startTsInclusive, window.endTsExclusive, limit]
                )
                return rows.map(decodeSleepSession)
            }
        case .workout:
            return try await writer.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM workout WHERE deviceId = ? AND startTs >= ? AND startTs < ? ORDER BY startTs ASC LIMIT ?",
                    arguments: [deviceId, window.startTsInclusive, window.endTsExclusive, limit]
                )
                return rows.map(decodeWorkout)
            }
        case .journal:
            return try await writer.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM journal WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day ASC LIMIT ?",
                    arguments: [deviceId, window.fromDay, window.toDay, limit]
                )
                return rows.map(decodeJournal)
            }
        }
    }

    private func tableName(_ table: PushAppendTable) -> String { table.wireName }

    private func decode(_ table: PushAppendTable, row: Row) throws -> PushAppendRecord {
        let rowId: Int64 = row["rowid"]
        switch table {
        case .hrSample:
            let ts: Int64 = row["ts"]
            let bpm: Int64 = row["bpm"]
            return PushAppendRecord(rowId: rowId, key: ["ts": .int(ts)], data: ["bpm": .int(bpm)])
        case .rrInterval:
            let ts: Int64 = row["ts"]
            let rrMs: Int64 = row["rrMs"]
            let seq: Int64 = row["seq"]
            return PushAppendRecord(
                rowId: rowId, key: ["ts": .int(ts), "rrMs": .int(rrMs), "seq": .int(seq)],
                data: [
                    "ord": intOrNull(row, "ord"), "srcChannel": intOrNull(row, "srcChannel"),
                    "tsSuspect": intOrNull(row, "tsSuspect"),
                ]
            )
        case .event:
            let ts: Int64 = row["ts"]
            let kind: String = row["kind"]
            let payload: String = row["payloadJSON"]
            return PushAppendRecord(rowId: rowId, key: ["ts": .int(ts), "kind": .string(kind)], data: ["payloadJSON": .string(payload)])
        case .battery:
            let ts: Int64 = row["ts"]
            let charging: Bool? = row["charging"]
            return PushAppendRecord(
                rowId: rowId, key: ["ts": .int(ts)],
                data: [
                    "soc": doubleOrNull(row, "soc"), "mv": intOrNull(row, "mv"),
                    "charging": charging.map(PushValue.bool) ?? .null,
                ]
            )
        case .spo2Sample:
            let ts: Int64 = row["ts"]
            let red: Int64 = row["red"]
            let ir: Int64 = row["ir"]
            return PushAppendRecord(rowId: rowId, key: ["ts": .int(ts)], data: ["red": .int(red), "ir": .int(ir)])
        case .skinTempSample:
            let ts: Int64 = row["ts"]
            let raw: Int64 = row["raw"]
            return PushAppendRecord(
                rowId: rowId, key: ["ts": .int(ts)],
                data: ["raw": .int(raw), "aux1Raw": intOrNull(row, "aux1Raw"), "aux2Raw": intOrNull(row, "aux2Raw")]
            )
        case .respSample:
            let ts: Int64 = row["ts"]
            let raw: Int64 = row["raw"]
            return PushAppendRecord(rowId: rowId, key: ["ts": .int(ts)], data: ["raw": .int(raw)])
        case .gravitySample:
            let ts: Int64 = row["ts"]
            let x: Double = row["x"], y: Double = row["y"], z: Double = row["z"]
            return PushAppendRecord(
                rowId: rowId, key: ["ts": .int(ts)],
                data: ["x": .double(x), "y": .double(y), "z": .double(z), "dynAccel": doubleOrNull(row, "dynAccel")]
            )
        }
    }

    private func decodeDailyMetric(_ row: Row) -> PushMutableRecord {
        let day: String = row["day"]
        return PushMutableRecord(
            key: ["day": .string(day)],
            data: [
                "totalSleepMin": doubleOrNull(row, "totalSleepMin"),
                "efficiency": doubleOrNull(row, "efficiency"),
                "deepMin": doubleOrNull(row, "deepMin"),
                "remMin": doubleOrNull(row, "remMin"),
                "lightMin": doubleOrNull(row, "lightMin"),
                "disturbances": intOrNull(row, "disturbances"),
                "restingHr": intOrNull(row, "restingHr"),
                "avgHrv": doubleOrNull(row, "avgHrv"),
                "recovery": doubleOrNull(row, "recovery"),
                "strain": doubleOrNull(row, "strain"),
                "exerciseCount": intOrNull(row, "exerciseCount"),
                "spo2Pct": doubleOrNull(row, "spo2Pct"),
                "skinTempDevC": doubleOrNull(row, "skinTempDevC"),
                "respRateBpm": doubleOrNull(row, "respRateBpm"),
                "steps": intOrNull(row, "steps"),
                "activeKcalEst": doubleOrNull(row, "activeKcalEst"),
                "spo2Red": intOrNull(row, "spo2Red"),
                "spo2Ir": intOrNull(row, "spo2Ir"),
            ]
        )
    }

    private func decodeSleepSession(_ row: Row) -> PushMutableRecord {
        let startTs: Int64 = row["startTs"]
        let endTs: Int64 = row["endTs"]
        let userEdited: Bool = row["userEdited"]
        return PushMutableRecord(
            key: ["startTs": .int(startTs)],
            data: [
                "endTs": .int(endTs),
                "efficiency": doubleOrNull(row, "efficiency"),
                "restingHr": intOrNull(row, "restingHr"),
                "avgHrv": doubleOrNull(row, "avgHrv"),
                "stagesJSON": stringOrNull(row, "stagesJSON"),
                "userEdited": .bool(userEdited),
                "startTsAdjusted": intOrNull(row, "startTsAdjusted"),
                "motionJSON": stringOrNull(row, "motionJSON"),
                "sleepStateJSON": stringOrNull(row, "sleepStateJSON"),
                "stagingSparse": intOrNull(row, "stagingSparse"),
            ]
        )
    }

    private func decodeWorkout(_ row: Row) -> PushMutableRecord {
        let startTs: Int64 = row["startTs"]
        let sport: String = row["sport"]
        let endTs: Int64 = row["endTs"]
        let source: String = row["source"]
        return PushMutableRecord(
            key: ["startTs": .int(startTs), "sport": .string(sport)],
            data: [
                "endTs": .int(endTs),
                "source": .string(source),
                "durationS": doubleOrNull(row, "durationS"),
                "energyKcal": doubleOrNull(row, "energyKcal"),
                "avgHr": intOrNull(row, "avgHr"),
                "maxHr": intOrNull(row, "maxHr"),
                "strain": doubleOrNull(row, "strain"),
                "distanceM": doubleOrNull(row, "distanceM"),
                "zonesJSON": stringOrNull(row, "zonesJSON"),
                "notes": stringOrNull(row, "notes"),
                "routePolyline": .null,   // no column in WhoopStore (Android-only field)
                "steps": intOrNull(row, "steps"),
            ]
        )
    }

    private func decodeJournal(_ row: Row) -> PushMutableRecord {
        let day: String = row["day"]
        let question: String = row["question"]
        let answeredYes: Bool = row["answeredYes"]
        return PushMutableRecord(
            key: ["day": .string(day), "question": .string(question)],
            data: [
                "answeredYes": .bool(answeredYes),
                "notes": stringOrNull(row, "notes"),
                "numericValue": doubleOrNull(row, "numericValue"),
            ]
        )
    }

    private func stringOrNull(_ row: Row, _ column: String) -> PushValue {
        (row[column] as String?).map(PushValue.string) ?? .null
    }

    private func intOrNull(_ row: Row, _ column: String) -> PushValue {
        (row[column] as Int64?).map(PushValue.int) ?? .null
    }

    private func doubleOrNull(_ row: Row, _ column: String) -> PushValue {
        (row[column] as Double?).map(PushValue.double) ?? .null
    }
}
