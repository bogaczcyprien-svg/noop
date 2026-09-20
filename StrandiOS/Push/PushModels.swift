import Foundation

/// A JSON scalar the push wire format can carry. Mirrors the Kotlin `Any?` registry values with an
/// explicit, exhaustive type instead of dynamic typing.
public enum PushValue: Equatable, Sendable {
    case null
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
}

public enum PushProtocolError: Error, Equatable {
    case invalid(String)
}

public protocol PushTable: Sendable {
    var wireName: String { get }
}

public enum PushAppendTable: String, CaseIterable, PushTable, Sendable {
    case hrSample, rrInterval, event, battery, spo2Sample, skinTempSample, respSample, gravitySample
    public var wireName: String { rawValue }
}

public enum PushMutableTable: String, CaseIterable, PushTable, Sendable {
    case dailyMetric, sleepSession, workout, journal
    public var wireName: String { rawValue }
}

/// Key excludes `deviceId` (batch-scoped); data contains only non-key registry columns.
public struct PushAppendRecord: Sendable {
    public let rowId: Int64
    public let key: [String: PushValue]
    public let data: [String: PushValue]

    public init(rowId: Int64, key: [String: PushValue], data: [String: PushValue]) {
        precondition(rowId > 0, "SQLite rowid must be positive")
        precondition(!key.isEmpty, "natural key must not be empty")
        self.rowId = rowId
        self.key = key
        self.data = data
    }
}

public struct PushMutableRecord: Sendable {
    public let key: [String: PushValue]
    public let data: [String: PushValue]

    public init(key: [String: PushValue], data: [String: PushValue]) {
        precondition(!key.isEmpty, "natural key must not be empty")
        self.key = key
        self.data = data
    }
}

public struct PushWindow: Sendable, Equatable {
    public let fromDay: String
    public let toDay: String
    public let startTsInclusive: Int64
    public let endTsExclusive: Int64

    public init(fromDay: String, toDay: String, startTsInclusive: Int64, endTsExclusive: Int64) {
        self.fromDay = fromDay
        self.toDay = toDay
        self.startTsInclusive = startTsInclusive
        self.endTsExclusive = endTsExclusive
    }

    /// The rolling 14-local-day window ending today, in `zone`.
    public static func ending(today: Date, zone: TimeZone) -> PushWindow {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let todayStart = cal.startOfDay(for: today)
        let fromStart = cal.date(byAdding: .day, value: -13, to: todayStart)!
        let endExclusive = cal.date(byAdding: .day, value: 1, to: todayStart)!
        let fmt = PushDayFormat.formatter
        return PushWindow(
            fromDay: fmt.string(from: fromStart),
            toDay: fmt.string(from: todayStart),
            startTsInclusive: Int64(fromStart.timeIntervalSince1970),
            endTsExclusive: Int64(endExclusive.timeIntervalSince1970)
        )
    }

    public static func days(from: Date, to: Date, zone: TimeZone) -> PushWindow {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let fromStart = cal.startOfDay(for: from)
        let toStart = cal.startOfDay(for: to)
        let endExclusive = cal.date(byAdding: .day, value: 1, to: toStart)!
        let fmt = PushDayFormat.formatter
        return PushWindow(
            fromDay: fmt.string(from: fromStart),
            toDay: fmt.string(from: toStart),
            startTsInclusive: Int64(fromStart.timeIntervalSince1970),
            endTsExclusive: Int64(endExclusive.timeIntervalSince1970)
        )
    }
}

/// `YYYY-MM-DD` calendar-day formatting, matching the wire format's `day` fields.
enum PushDayFormat {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

/// Persisted and transmitted cursor. The fingerprint is SHA-256, never raw key material.
public struct PushCursor: Sendable, Equatable {
    public let rowId: Int64
    public let naturalKeyFingerprint: String

    public init(rowId: Int64, naturalKeyFingerprint: String) {
        self.rowId = rowId
        self.naturalKeyFingerprint = naturalKeyFingerprint
    }
}

public struct PushWindowProgress: Sendable {
    public let window: PushWindow
    public let batchId: String
    public let dayHashes: [String: String]

    public init(window: PushWindow, batchId: String, dayHashes: [String: String] = [:]) {
        self.window = window
        self.batchId = batchId
        self.dayHashes = dayHashes
    }
}

/// Fully materialized bounded request.
public struct PushBatch: Sendable {
    public let protocolVersion: String
    public let batchId: String
    public let sourceId: String
    public let table: any PushTable
    public let deviceId: String
    public let mode: String
    public let startCursor: PushCursor?
    public let endCursor: PushCursor?
    public let recordCount: Int
    public let window: PushWindow?
    public let replacementId: String?
    public let part: Int?
    public let parts: Int?
    public let body: Data
}

public struct PushTransportResponse: Sendable {
    public let statusCode: Int
    public let body: Data
}

public enum PushResult: Sendable {
    case accepted(batchId: String, recordCount: Int, hasMore: Bool, batchCount: Int = 1)
    case noData
    case rejected(reason: String, retryable: Bool, failure: PushFailure?)
}

public struct PushRunResult: Sendable {
    public var acceptedBatches: Int = 0
    public var rejectedBatches: Int = 0
    public var hasMoreAppendRows: Bool = false
    public var acceptedRecords: Int = 0
    public var hasRetryableFailure: Bool = false
    public var nextDeviceIndex: Int = 0
    public var hasMoreDevices: Bool = false
    public var failure: PushFailure?
}

public protocol PushTransport {
    func capabilities() async -> PushCapabilitiesResult
    func post(_ batch: PushBatch) async throws -> PushTransportResponse
}

public protocol PushProgressStore {
    func knownDeviceIds() async -> Set<String>
    func rememberDeviceId(_ id: String) async
    func cursor(table: PushAppendTable, deviceId: String) async -> PushCursor?
    func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async
    func window(table: PushMutableTable, deviceId: String) async -> PushWindowProgress?
    func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async
}

/// All methods return bounded snapshots; no open transaction survives past the call.
public protocol PushSnapshotSource {
    func knownDeviceIds(capabilities: PushCapabilities) async -> [String]
    func appendRecord(table: PushAppendTable, deviceId: String, atRowId rowId: Int64) async throws -> PushAppendRecord?
    func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord]
    func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord]
}
