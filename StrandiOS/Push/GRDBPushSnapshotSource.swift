import Foundation
import GRDB
import WhoopStore

/// Reads bounded snapshots straight off `WhoopStore`'s SQLite file for the push protocol.
///
/// Covers the streams verified against the current schema (`Packages/WhoopStore/Sources/WhoopStore/Database.swift`):
/// `hrSample`, `rrInterval`, `event`, `battery` (append) and `dailyMetric` (replace-window). The
/// remaining registry streams (`spo2Sample`, `skinTempSample`, `respSample`, `gravitySample`,
/// `sleepSession`, `workout`, `journal`) follow the identical pattern and can be added the same way —
/// left out of this first pass to keep every column mapping individually checked against a migration.
public struct GRDBPushSnapshotSource: PushSnapshotSource {
    private let store: WhoopStore
    public static let supportedAppendTables: Set<PushAppendTable> = [.hrSample, .rrInterval, .event, .battery]
    public static let supportedMutableTables: Set<PushMutableTable> = [.dailyMetric]

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
        guard table == .dailyMetric else { return [] }
        let writer = store.registryWriter
        return try await writer.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM dailyMetric WHERE deviceId = ? AND day >= ? AND day <= ? ORDER BY day ASC LIMIT ?",
                arguments: [deviceId, window.fromDay, window.toDay, limit]
            )
            return rows.map(decodeDailyMetric)
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
        default:
            throw PushProtocolError.invalid("\(table.wireName) is not implemented by GRDBPushSnapshotSource")
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

    private func intOrNull(_ row: Row, _ column: String) -> PushValue {
        (row[column] as Int64?).map(PushValue.int) ?? .null
    }

    private func doubleOrNull(_ row: Row, _ column: String) -> PushValue {
        (row[column] as Double?).map(PushValue.double) ?? .null
    }
}
