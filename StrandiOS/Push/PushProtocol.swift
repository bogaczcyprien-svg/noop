import Foundation
import CryptoKit

/// Deterministic, bounded NDJSON encoder and acknowledgement codec for push protocol 1.0.
/// Port of the Android `PushProtocol.kt` — same wire shapes, same limits, same registry.
public enum PushProtocol {
    public static let version = "1.0"
    public static let maxRecords = 5_000
    /// Hard limit for the decoded UTF-8 NDJSON entity, before optional content coding.
    public static let maxBodyBytes = 4 * 1024 * 1024
    public static let maxWireBodyBytes = maxBodyBytes + 64 * 1024
    public static let maxAckBytes = 16 * 1024
    static let maxMutableSnapshotRecords = 1_000
    static let maxMutableSnapshotEncodedBytes = 2 * 1024 * 1024
    static let forbiddenRemoteControlMembers: Set<String> = [
        "command", "commands", "endpoint", "url", "cadence", "schema", "fields",
    ]

    static let registry: [String: (key: [String], data: [String])] = [
        "hrSample": (["ts"], ["bpm"]),
        "rrInterval": (["ts", "rrMs", "seq"], ["ord", "srcChannel", "tsSuspect"]),
        "event": (["ts", "kind"], ["payloadJSON"]),
        "battery": (["ts"], ["soc", "mv", "charging"]),
        "spo2Sample": (["ts"], ["red", "ir"]),
        "skinTempSample": (["ts"], ["raw", "aux1Raw", "aux2Raw"]),
        "respSample": (["ts"], ["raw"]),
        "gravitySample": (["ts"], ["x", "y", "z", "dynAccel"]),
        "dailyMetric": (["day"], [
            "totalSleepMin", "efficiency", "deepMin", "remMin", "lightMin", "disturbances",
            "restingHr", "avgHrv", "recovery", "strain", "exerciseCount", "spo2Pct",
            "skinTempDevC", "respRateBpm", "steps", "activeKcalEst", "spo2Red", "spo2Ir",
        ]),
        "sleepSession": (["startTs"], [
            "endTs", "efficiency", "restingHr", "avgHrv", "stagesJSON", "userEdited",
            "startTsAdjusted", "motionJSON", "sleepStateJSON", "stagingSparse",
        ]),
        "workout": (["startTs", "sport"], [
            "endTs", "source", "durationS", "energyKcal", "avgHr", "maxHr", "strain",
            "distanceM", "zonesJSON", "notes", "routePolyline", "steps",
        ]),
        "journal": (["day", "question"], ["answeredYes", "notes", "numericValue"]),
    ]

    private static let uuidPlaceholder = "00000000-0000-0000-0000-000000000000"

    public static func appendBatch(
        table: PushAppendTable,
        sourceId: String,
        deviceId: String,
        startCursor: PushCursor?,
        records: [PushAppendRecord]
    ) throws -> PushBatch {
        try validateUuid(sourceId, name: "sourceId")
        guard !records.isEmpty else { throw PushProtocolError.invalid("append batch must contain a record") }
        for i in 1..<records.count where records[i - 1].rowId >= records[i].rowId {
            throw PushProtocolError.invalid("append records must be strictly ordered by rowid")
        }
        for r in records { try validateRecord(table, key: r.key, data: r.data) }

        let candidates = Array(records.prefix(maxRecords))
        var selectedRows: [PushAppendRecord] = []
        var selectedLines: [Data] = []
        var rowBytes = 0
        for candidate in candidates {
            let encodedRow = try encodeRecordLine(key: candidate.key, data: candidate.data)
            let end = try cursorFor(table: table, deviceId: deviceId, record: candidate)
            let candidateCount = selectedRows.count + 1
            let header = try appendHeader(
                sourceId: sourceId, table: table, deviceId: deviceId,
                start: startCursor, end: end, count: candidateCount, batchId: uuidPlaceholder
            )
            if header.count + rowBytes + encodedRow.count > maxBodyBytes { break }
            selectedRows.append(candidate)
            selectedLines.append(encodedRow)
            rowBytes += encodedRow.count
        }
        guard !selectedRows.isEmpty else {
            throw PushProtocolError.invalid("first append record exceeds the 4 MiB decoded batch limit")
        }

        let endCursor = try cursorFor(table: table, deviceId: deviceId, record: selectedRows.last!)
        let identity = appendIdentity(
            sourceId: sourceId, table: table, deviceId: deviceId,
            start: startCursor, end: endCursor, count: selectedRows.count
        )
        let batchId = stableUuid(header: identity, lines: selectedLines)
        let header = try appendHeader(
            sourceId: sourceId, table: table, deviceId: deviceId,
            start: startCursor, end: endCursor, count: selectedRows.count, batchId: batchId
        )
        let body = concatenate(header: header, lines: selectedLines)
        return PushBatch(
            protocolVersion: version, batchId: batchId, sourceId: sourceId, table: table,
            deviceId: deviceId, mode: "append", startCursor: startCursor, endCursor: endCursor,
            recordCount: selectedRows.count, window: nil, replacementId: nil, part: nil, parts: nil,
            body: body
        )
    }

    /// Builds every bounded part of one authoritative replacement. Empty snapshots produce one part.
    public static func mutableBatches(
        table: PushMutableTable,
        sourceId: String,
        deviceId: String,
        window: PushWindow,
        records: [PushMutableRecord]
    ) throws -> [PushBatch] {
        try validateUuid(sourceId, name: "sourceId")
        for r in records { try validateRecord(table, key: r.key, data: r.data) }
        var seenKeys = Set<String>()
        for r in records {
            let kj = try orderedObjectJson(r.key)
            if !seenKeys.insert(kj).inserted {
                throw PushProtocolError.invalid("replace_window contains a duplicate key")
            }
        }
        let lines = try records.map { try encodeRecordLine(key: $0.key, data: $0.data) }
        let replacementId = stableUuid(
            header: [
                ("deviceId", .string(deviceId)), ("delivery", .string("replace_window")),
                ("protocolVersion", .string(version)), ("sourceId", .string(sourceId)),
                ("stream", .string(table.wireName)),
            ],
            lines: lines,
            extraCanonical: try canonicalJson(.object(selectorBounds(table: table, window: window)))
        )

        var chunks: [[Data]] = []
        var current: [Data] = []
        var currentBytes = 0
        for line in lines {
            let nextCount = current.count + 1
            let conservativeHeader = try mutableHeader(
                sourceId: sourceId, table: table, deviceId: deviceId, window: window,
                replacementId: replacementId, part: .max, parts: .max, count: nextCount,
                batchId: uuidPlaceholder
            )
            if nextCount > maxRecords || conservativeHeader.count + currentBytes + line.count > maxBodyBytes {
                guard !current.isEmpty else {
                    throw PushProtocolError.invalid("first replace_window record exceeds the 4 MiB decoded batch limit")
                }
                chunks.append(current)
                current = []
                currentBytes = 0
            }
            let oneHeader = try mutableHeader(
                sourceId: sourceId, table: table, deviceId: deviceId, window: window,
                replacementId: replacementId, part: .max, parts: .max, count: 1, batchId: uuidPlaceholder
            )
            if oneHeader.count + line.count > maxBodyBytes {
                throw PushProtocolError.invalid("replace_window record exceeds the 4 MiB decoded batch limit")
            }
            current.append(line)
            currentBytes += line.count
        }
        if !current.isEmpty || chunks.isEmpty { chunks.append(current) }

        let parts = chunks.count
        return try chunks.enumerated().map { index, partLines in
            let part = index + 1
            let identity = mutableIdentity(
                sourceId: sourceId, table: table, deviceId: deviceId, window: window,
                replacementId: replacementId, part: part, parts: parts, count: partLines.count
            )
            let batchId = stableUuid(header: identity, lines: partLines)
            let header = try mutableHeader(
                sourceId: sourceId, table: table, deviceId: deviceId, window: window,
                replacementId: replacementId, part: part, parts: parts, count: partLines.count,
                batchId: batchId
            )
            let body = concatenate(header: header, lines: partLines)
            return PushBatch(
                protocolVersion: version, batchId: batchId, sourceId: sourceId, table: table,
                deviceId: deviceId, mode: "replace_window", startCursor: nil, endCursor: nil,
                recordCount: partLines.count, window: window, replacementId: replacementId,
                part: part, parts: parts, body: body
            )
        }
    }

    /// SHA-256(stream LF device LF compact-natural-key), matching cursor invalidation contract.
    public static func keyFingerprint(table: PushAppendTable, deviceId: String, key: [String: PushValue]) throws -> String {
        try validateRecordKeys(table, key: key)
        let subject = "\(table.wireName)\n\(deviceId)\n\(try orderedObjectJson(key))"
        return sha256Hex(Data(subject.utf8))
    }

    static func mutableRecordEncodedSize(table: PushMutableTable, record: PushMutableRecord) throws -> Int {
        try validateRecord(table, key: record.key, data: record.data)
        return try encodeRecordLine(key: record.key, data: record.data).count
    }

    /// Stable local content identity. It is progress metadata and is never sent to the receiver.
    static func mutableSnapshotHash(table: PushMutableTable, records: [PushMutableRecord]) throws -> String {
        let lines = try records
            .map { try encodeRecordLine(key: $0.key, data: $0.data) }
            .sorted { compareBytes($0, $1) < 0 }
        var hasher = SHA256()
        hasher.update(data: Data("noop-push-day-hash\n\(version)\n\(table.wireName)\n".utf8))
        for line in lines { hasher.update(data: line) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Canonical JSON

    indirect enum JSONNode {
        case null
        case string(String)
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case object([String: PushValue])
        case orderedObject([(String, JSONNode)])
    }

    static func canonicalJson(_ node: JSONNode) throws -> String {
        var out = ""
        try appendCanonical(node, sortMaps: true, into: &out)
        return out
    }

    private static func orderedObjectJson(_ value: [String: PushValue]) throws -> String {
        var out = ""
        try appendCanonical(.object(value), sortMaps: false, into: &out)
        return out
    }

    private static func appendCanonical(_ node: JSONNode, sortMaps: Bool, into out: inout String) throws {
        switch node {
        case .null:
            out += "null"
        case .string(let s):
            appendQuoted(s, into: &out)
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            guard d.isFinite else { throw PushProtocolError.invalid("non-finite number is not valid JSON") }
            out += doubleToString(d)
        case .object(let map):
            let entries = sortMaps ? map.sorted { $0.key < $1.key } : Array(map)
            out += "{"
            for (i, (k, v)) in entries.enumerated() {
                if i > 0 { out += "," }
                appendQuoted(k, into: &out)
                out += ":"
                try appendCanonical(pushValueNode(v), sortMaps: sortMaps, into: &out)
            }
            out += "}"
        case .orderedObject(let entries):
            out += "{"
            for (i, (k, v)) in entries.enumerated() {
                if i > 0 { out += "," }
                appendQuoted(k, into: &out)
                out += ":"
                try appendCanonical(v, sortMaps: sortMaps, into: &out)
            }
            out += "}"
        }
    }

    private static func pushValueNode(_ v: PushValue) -> JSONNode {
        switch v {
        case .null: return .null
        case .string(let s): return .string(s)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .bool(let b): return .bool(b)
        }
    }

    private static func doubleToString(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e15 {
            return String(format: "%.1f", d)
        }
        return "\(d)"
    }

    private static func appendQuoted(_ value: String, into out: inout String) {
        out += "\""
        for ch in value.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        out += "\""
    }

    private static func encodeRecordLine(key: [String: PushValue], data: [String: PushValue]) throws -> Data {
        let node: JSONNode = .orderedObject([
            ("data", .object(data)), ("key", .object(key)), ("type", .string("record")),
        ])
        var s = try canonicalJson(node)
        s += "\n"
        return Data(s.utf8)
    }

    private static func appendIdentity(
        sourceId: String, table: PushAppendTable, deviceId: String,
        start: PushCursor?, end: PushCursor, count: Int
    ) -> [(String, JSONNode)] {
        [
            ("delivery", .string("append")),
            ("deviceId", .string(deviceId)),
            ("endCursor", cursorNode(end)),
            ("protocolVersion", .string(version)),
            ("recordCount", .int(Int64(count))),
            ("sourceId", .string(sourceId)),
            ("startCursor", start.map(cursorNode) ?? .null),
            ("stream", .string(table.wireName)),
            ("type", .string("batch")),
        ]
    }

    private static func appendHeader(
        sourceId: String, table: PushAppendTable, deviceId: String,
        start: PushCursor?, end: PushCursor, count: Int, batchId: String
    ) throws -> Data {
        var entries = appendIdentity(sourceId: sourceId, table: table, deviceId: deviceId, start: start, end: end, count: count)
        entries.append(("batchId", .string(batchId)))
        var s = try canonicalJson(.orderedObject(entries))
        s += "\n"
        return Data(s.utf8)
    }

    private static func mutableIdentity(
        sourceId: String, table: PushMutableTable, deviceId: String, window: PushWindow,
        replacementId: String, part: Int, parts: Int, count: Int
    ) -> [(String, JSONNode)] {
        var windowNode = selectorBoundsNode(table: table, window: window)
        windowNode.append(("part", .int(Int64(part))))
        windowNode.append(("parts", .int(Int64(parts))))
        windowNode.append(("replacementId", .string(replacementId)))
        return [
            ("delivery", .string("replace_window")),
            ("deviceId", .string(deviceId)),
            ("endCursor", .null),
            ("protocolVersion", .string(version)),
            ("recordCount", .int(Int64(count))),
            ("sourceId", .string(sourceId)),
            ("startCursor", .null),
            ("stream", .string(table.wireName)),
            ("type", .string("batch")),
            ("window", .orderedObject(windowNode)),
        ]
    }

    private static func mutableHeader(
        sourceId: String, table: PushMutableTable, deviceId: String, window: PushWindow,
        replacementId: String, part: Int, parts: Int, count: Int, batchId: String
    ) throws -> Data {
        var entries = mutableIdentity(
            sourceId: sourceId, table: table, deviceId: deviceId, window: window,
            replacementId: replacementId, part: part, parts: parts, count: count
        )
        entries.append(("batchId", .string(batchId)))
        var s = try canonicalJson(.orderedObject(entries))
        s += "\n"
        return Data(s.utf8)
    }

    private static func selectorBounds(table: PushMutableTable, window: PushWindow) -> [String: PushValue] {
        switch table {
        case .dailyMetric, .journal:
            let end = addOneDay(to: window.toDay)
            return ["endExclusive": .string(end), "selector": .string("day"), "startInclusive": .string(window.fromDay)]
        case .sleepSession, .workout:
            return [
                "endExclusive": .int(window.endTsExclusive), "selector": .string("startTs"),
                "startInclusive": .int(window.startTsInclusive),
            ]
        }
    }

    private static func selectorBoundsNode(table: PushMutableTable, window: PushWindow) -> [(String, JSONNode)] {
        switch table {
        case .dailyMetric, .journal:
            let end = addOneDay(to: window.toDay)
            return [("endExclusive", .string(end)), ("selector", .string("day")), ("startInclusive", .string(window.fromDay))]
        case .sleepSession, .workout:
            return [
                ("endExclusive", .int(window.endTsExclusive)), ("selector", .string("startTs")),
                ("startInclusive", .int(window.startTsInclusive)),
            ]
        }
    }

    private static func addOneDay(to day: String) -> String {
        let fmt = PushDayFormat.formatter
        guard let date = fmt.date(from: day) else { return day }
        let next = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: date)!
        return fmt.string(from: next)
    }

    private static func cursorFor(table: PushAppendTable, deviceId: String, record: PushAppendRecord) throws -> PushCursor {
        PushCursor(rowId: record.rowId, naturalKeyFingerprint: try keyFingerprint(table: table, deviceId: deviceId, key: record.key))
    }

    private static func cursorNode(_ cursor: PushCursor) -> JSONNode {
        .orderedObject([("keySha256", .string(cursor.naturalKeyFingerprint)), ("rowId", .int(cursor.rowId))])
    }

    private static func stableUuid(header: [(String, JSONNode)], lines: [Data], extraCanonical: String? = nil) -> String {
        var hasher = SHA256()
        let json = (try? canonicalJson(.orderedObject(header))) ?? ""
        hasher.update(data: Data(json.utf8))
        if let extra = extraCanonical { hasher.update(data: Data(extra.utf8)) }
        hasher.update(data: Data([0x0A]))
        for line in lines { hasher.update(data: line) }
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let u = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return u.uuidString.lowercased()
    }

    private static func concatenate(header: Data, lines: [Data]) -> Data {
        var out = header
        for l in lines { out.append(l) }
        return out
    }

    private static func compareBytes(_ a: Data, _ b: Data) -> Int {
        let common = min(a.count, b.count)
        for i in 0..<common {
            let d = Int(a[a.startIndex + i]) - Int(b[b.startIndex + i])
            if d != 0 { return d }
        }
        return a.count - b.count
    }

    private static func validateRecord(_ table: any PushTable, key: [String: PushValue], data: [String: PushValue]) throws {
        guard let spec = registry[table.wireName] else { throw PushProtocolError.invalid("unknown stream") }
        guard Array(key.keys).sorted() == spec.key.sorted(), key.keys.count == spec.key.count else {
            throw PushProtocolError.invalid("\(table.wireName) key does not match registry")
        }
        guard Set(data.keys) == Set(spec.data), data.count == spec.data.count else {
            throw PushProtocolError.invalid("\(table.wireName) data does not match registry")
        }
        if key["deviceId"] != nil || data["deviceId"] != nil || data["synced"] != nil {
            throw PushProtocolError.invalid("batch-scoped or local-only column in record")
        }
    }

    private static func validateRecordKeys(_ table: PushAppendTable, key: [String: PushValue]) throws {
        guard let spec = registry[table.wireName], Set(key.keys) == Set(spec.key), key.count == spec.key.count else {
            throw PushProtocolError.invalid("\(table.wireName) key does not match registry")
        }
    }

    private static func validateUuid(_ value: String, name: String) throws {
        guard let u = UUID(uuidString: value), u.uuidString.lowercased() == value else {
            throw PushProtocolError.invalid("\(name) must be a lowercase canonical UUID")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct PushAck: Equatable {
    public let protocolVersion: String
    public let batchId: String
    public let stream: String
    public let deviceId: String
    public let endCursor: PushCursor?
    public let acceptedRows: Int
    public let status: String

    public func exactlyMatches(_ batch: PushBatch) -> Bool {
        protocolVersion == batch.protocolVersion && batchId == batch.batchId &&
            stream == batch.table.wireName && deviceId == batch.deviceId &&
            endCursor == batch.endCursor && acceptedRows == batch.recordCount && status == "accepted"
    }

    public static func parse(_ data: Data) throws -> PushAck {
        guard data.count <= PushProtocol.maxAckBytes else { throw PushProtocolError.invalid("ack exceeds size limit") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PushProtocolError.invalid("ack is not valid JSON")
        }
        let expected: Set<String> = ["protocolVersion", "batchId", "stream", "deviceId", "endCursor", "acceptedRows", "status"]
        guard expected.isSubset(of: Set(obj.keys)) else {
            throw PushProtocolError.invalid("ack is missing required protocol 1.0 members")
        }
        if !Set(obj.keys).isDisjoint(with: PushProtocol.forbiddenRemoteControlMembers) {
            throw PushProtocolError.invalid("ack contains forbidden remote-control metadata")
        }
        func string(_ name: String) throws -> String {
            guard let s = obj[name] as? String, !s.isEmpty else {
                throw PushProtocolError.invalid("ack.\(name) must be a non-empty string")
            }
            return s
        }
        func int(_ name: String) throws -> Int {
            guard let n = obj[name] as? NSNumber else {
                throw PushProtocolError.invalid("ack.\(name) must be an integer")
            }
            return n.intValue
        }
        var cursor: PushCursor?
        if let raw = obj["endCursor"], !(raw is NSNull) {
            guard let rawObj = raw as? [String: Any],
                  Set(["rowId", "keySha256"]).isSubset(of: Set(rawObj.keys)) else {
                throw PushProtocolError.invalid("ack.endCursor is missing required protocol 1.0 members")
            }
            guard let rowId = (rawObj["rowId"] as? NSNumber)?.int64Value else {
                throw PushProtocolError.invalid("ack.endCursor.rowId must be an integer")
            }
            guard let sha = rawObj["keySha256"] as? String, sha.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw PushProtocolError.invalid("ack.endCursor.keySha256 must be lowercase SHA-256")
            }
            cursor = PushCursor(rowId: rowId, naturalKeyFingerprint: sha)
        }
        return PushAck(
            protocolVersion: try string("protocolVersion"), batchId: try string("batchId"),
            stream: try string("stream"), deviceId: try string("deviceId"),
            endCursor: cursor, acceptedRows: try int("acceptedRows"), status: try string("status")
        )
    }
}
