import Foundation

/// Coordinates bounded snapshots and transport. Port of the Android `PushCoordinator.kt`.
public actor PushCoordinator {
    private let source: PushSnapshotSource
    private let transport: PushTransport
    private let progress: PushProgressStore
    private let sourceId: String
    private let zone: TimeZone
    private let today: () -> Date

    public init(
        source: PushSnapshotSource, transport: PushTransport, progress: PushProgressStore,
        sourceId: String, zone: TimeZone = .current, today: @escaping () -> Date = Date.init
    ) {
        self.source = source
        self.transport = transport
        self.progress = progress
        self.sourceId = sourceId
        self.zone = zone
        self.today = today
    }

    func pushAppend(table: PushAppendTable, deviceId: String) async -> PushResult {
        let stored = await progress.cursor(table: table, deviceId: deviceId)
        var effective: PushCursor?
        if let stored, stored.rowId > 0 {
            do {
                let atCursor = try await source.appendRecord(table: table, deviceId: deviceId, atRowId: stored.rowId)
                let fingerprint = try atCursor.map { try PushProtocol.keyFingerprint(table: table, deviceId: deviceId, key: $0.key) }
                effective = (fingerprint == stored.naturalKeyFingerprint) ? stored : nil
            } catch {
                return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
            }
        }
        let rows: [PushAppendRecord]
        do {
            rows = try await source.appendRows(table: table, deviceId: deviceId, afterRowId: effective?.rowId ?? 0, limit: PushProtocol.maxRecords + 1)
        } catch {
            return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
        }
        if rows.isEmpty { return .noData }
        let batch: PushBatch
        do {
            batch = try PushProtocol.appendBatch(table: table, sourceId: sourceId, deviceId: deviceId, startCursor: effective, records: rows)
        } catch {
            return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
        }
        let accepted = await deliver(batch)
        guard case .accepted = accepted, let end = batch.endCursor else { return accepted }
        await progress.saveCursor(table: table, deviceId: deviceId, cursor: end)
        if case .accepted(let batchId, let recordCount, _, let batchCount) = accepted {
            return .accepted(batchId: batchId, recordCount: recordCount, hasMore: rows.count > batch.recordCount, batchCount: batchCount)
        }
        return accepted
    }

    func pushMutable(table: PushMutableTable, deviceId: String) async -> PushResult {
        let fullWindow = PushWindow.ending(today: today(), zone: zone)
        let rows: [PushMutableRecord]
        do {
            rows = try await source.mutableRows(table: table, deviceId: deviceId, window: fullWindow, limit: PushProtocol.maxMutableSnapshotRecords + 1)
        } catch {
            return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
        }
        if rows.count > PushProtocol.maxMutableSnapshotRecords {
            return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
        }

        let dayFmt = PushDayFormat.formatter
        guard let fromDate = dayFmt.date(from: fullWindow.fromDay), let toDate = dayFmt.date(from: fullWindow.toDay) else {
            return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        var days: [String] = []
        var cursorDate = fromDate
        while cursorDate <= toDate {
            days.append(dayFmt.string(from: cursorDate))
            cursorDate = cal.date(byAdding: .day, value: 1, to: cursorDate)!
        }

        var recordsByDay: [String: [PushMutableRecord]] = Dictionary(uniqueKeysWithValues: days.map { ($0, []) })
        var encodedBytes = 0
        for record in rows {
            let size: Int
            do { size = try PushProtocol.mutableRecordEncodedSize(table: table, record: record) } catch {
                return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
            }
            encodedBytes += size
            if encodedBytes > PushProtocol.maxMutableSnapshotEncodedBytes {
                return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
            }
            guard let day = mutableRecordDay(table: table, record: record), recordsByDay[day] != nil else {
                return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
            }
            recordsByDay[day]!.append(record)
        }

        var currentHashes: [String: String] = [:]
        for day in days {
            guard let hash = try? PushProtocol.mutableSnapshotHash(table: table, records: recordsByDay[day] ?? []) else {
                return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
            }
            currentHashes[day] = hash
        }
        let previousHashes = await progress.window(table: table, deviceId: deviceId)?.dayHashes ?? [:]
        let changedDays = days.filter { previousHashes[$0] != currentHashes[$0] }
        if changedDays.isEmpty { return .noData }

        guard let firstChanged = dayFmt.date(from: changedDays.first!), let lastChanged = dayFmt.date(from: changedDays.last!) else {
            return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
        }
        let window = PushWindow.days(from: firstChanged, to: lastChanged, zone: zone)
        let changedRows = days.filter { $0 >= changedDays.first! && $0 <= changedDays.last! }.flatMap { recordsByDay[$0] ?? [] }

        let batches: [PushBatch]
        do {
            batches = try PushProtocol.mutableBatches(table: table, sourceId: sourceId, deviceId: deviceId, window: window, records: changedRows)
        } catch {
            return .rejected(reason: PushFailureCode.localData.rawValue, retryable: false, failure: PushFailure(code: .localData))
        }
        for batch in batches {
            let accepted = await deliver(batch)
            guard case .accepted = accepted else { return accepted }
        }
        let replacementId = batches.first?.replacementId ?? batches.first?.batchId ?? ""
        await progress.saveWindow(table: table, deviceId: deviceId, progress: PushWindowProgress(window: fullWindow, batchId: replacementId, dayHashes: currentHashes))
        return .accepted(batchId: replacementId, recordCount: changedRows.count, hasMore: false, batchCount: batches.count)
    }

    private func mutableRecordDay(table: PushMutableTable, record: PushMutableRecord) -> String? {
        switch table {
        case .dailyMetric, .journal:
            if case .string(let day)? = record.key["day"] { return day }
            return nil
        case .sleepSession, .workout:
            guard case .int(let ts)? = record.key["startTs"] else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            return PushDayFormat.formatter.string(from: date)
        }
    }

    /// One append page and one checksum-minimized mutable replacement per actual source device.
    public func pushKnownDevices(
        startDeviceIndex: Int = 0, maxDevices: Int = .max, capabilities: PushCapabilities = .all
    ) async -> PushRunResult {
        if capabilities.isEmpty { return PushRunResult() }
        let live = await source.knownDeviceIds(capabilities: capabilities).filter { !$0.isEmpty }
        for id in Set(live) { await progress.rememberDeviceId(id) }
        let known = await progress.knownDeviceIds()
        let devices = Array(Set(live).union(known)).filter { !$0.isEmpty }.sorted()
        if devices.isEmpty { return PushRunResult() }

        let start = devices.isEmpty ? 0 : startDeviceIndex % devices.count
        let selectedCount = min(maxDevices, devices.count)
        let selectedDevices = (0..<selectedCount).map { devices[(start + $0) % devices.count] }
        let nextDeviceIndex = devices.isEmpty ? 0 : (start + selectedCount) % devices.count

        var result = PushRunResult()
        for deviceId in selectedDevices {
            for table in PushAppendTable.allCases where capabilities.appendTables.contains(table) {
                switch await pushAppend(table: table, deviceId: deviceId) {
                case .accepted(_, let recordCount, let hasMore, let batchCount):
                    result.acceptedBatches += batchCount
                    result.acceptedRecords += recordCount
                    result.hasMoreAppendRows = result.hasMoreAppendRows || hasMore
                case .rejected(_, let retryable, let failure):
                    result.rejectedBatches += 1
                    if result.failure == nil || (retryable && !result.hasRetryableFailure) { result.failure = failure }
                    result.hasRetryableFailure = result.hasRetryableFailure || retryable
                case .noData:
                    break
                }
            }
            for table in PushMutableTable.allCases where capabilities.mutableTables.contains(table) {
                switch await pushMutable(table: table, deviceId: deviceId) {
                case .accepted(_, let recordCount, _, let batchCount):
                    result.acceptedBatches += batchCount
                    result.acceptedRecords += recordCount
                case .rejected(_, let retryable, let failure):
                    result.rejectedBatches += 1
                    if result.failure == nil || (retryable && !result.hasRetryableFailure) { result.failure = failure }
                    result.hasRetryableFailure = result.hasRetryableFailure || retryable
                case .noData:
                    break
                }
            }
        }
        result.nextDeviceIndex = nextDeviceIndex
        result.hasMoreDevices = devices.count > selectedCount
        return result
    }

    private func deliver(_ batch: PushBatch) async -> PushResult {
        let response: PushTransportResponse
        do {
            response = try await transport.post(batch)
        } catch let e as PushTransportException {
            return .rejected(reason: e.failure.safeCode, retryable: e.failure.retryable, failure: e.failure)
        } catch {
            let f = PushFailure(code: .networkIO)
            return .rejected(reason: f.safeCode, retryable: f.retryable, failure: f)
        }
        if response.body.count > PushProtocol.maxAckBytes {
            let f = PushFailure(code: .ackInvalid)
            return .rejected(reason: f.safeCode, retryable: f.retryable, failure: f)
        }
        guard (200...299).contains(response.statusCode) else {
            let f = PushFailure.http(status: response.statusCode, receiverCode: parseErrorCode(response.body))
            return .rejected(reason: f.safeCode, retryable: f.retryable, failure: f)
        }
        guard let ack = try? PushAck.parse(response.body), ack.exactlyMatches(batch) else {
            let f = PushFailure(code: .ackInvalid)
            return .rejected(reason: f.safeCode, retryable: f.retryable, failure: f)
        }
        return .accepted(batchId: batch.batchId, recordCount: batch.recordCount, hasMore: false, batchCount: 1)
    }

    private func parseErrorCode(_ body: Data) -> String? {
        guard body.count <= PushProtocol.maxAckBytes,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              obj["type"] as? String == "error", let code = obj["code"] as? String
        else { return nil }
        return code
    }
}
