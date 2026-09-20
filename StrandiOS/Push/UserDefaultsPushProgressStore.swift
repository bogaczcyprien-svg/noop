import Foundation

/// Persists append cursors and replace-window day-hashes in `UserDefaults` — small, per-installation
/// state that never needs a database migration. Scale is a handful of streams times a handful of
/// devices, so a plist-backed dictionary is simpler than adding tables to `WhoopStore`.
public actor UserDefaultsPushProgressStore: PushProgressStore {
    private let defaults: UserDefaults
    private let keyPrefix = "noop.push."

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func knownDeviceIds() async -> Set<String> {
        Set(defaults.stringArray(forKey: keyPrefix + "knownDevices") ?? [])
    }

    public func rememberDeviceId(_ id: String) async {
        var known = await knownDeviceIds()
        guard known.insert(id).inserted else { return }
        defaults.set(Array(known), forKey: keyPrefix + "knownDevices")
    }

    public func cursor(table: PushAppendTable, deviceId: String) async -> PushCursor? {
        guard let data = defaults.data(forKey: cursorKey(table, deviceId)),
              let stored = try? JSONDecoder().decode(StoredCursor.self, from: data)
        else { return nil }
        return PushCursor(rowId: stored.rowId, naturalKeyFingerprint: stored.keySha256)
    }

    public func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async {
        let stored = StoredCursor(rowId: cursor.rowId, keySha256: cursor.naturalKeyFingerprint)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: cursorKey(table, deviceId))
    }

    public func window(table: PushMutableTable, deviceId: String) async -> PushWindowProgress? {
        guard let data = defaults.data(forKey: windowKey(table, deviceId)),
              let stored = try? JSONDecoder().decode(StoredWindow.self, from: data)
        else { return nil }
        return PushWindowProgress(
            window: PushWindow(fromDay: stored.fromDay, toDay: stored.toDay, startTsInclusive: stored.startTs, endTsExclusive: stored.endTs),
            batchId: stored.batchId,
            dayHashes: stored.dayHashes
        )
    }

    public func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async {
        let stored = StoredWindow(
            fromDay: progress.window.fromDay, toDay: progress.window.toDay,
            startTs: progress.window.startTsInclusive, endTs: progress.window.endTsExclusive,
            batchId: progress.batchId, dayHashes: progress.dayHashes
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: windowKey(table, deviceId))
    }

    /// Drops all cursors/windows — used when the destination (endpoint or token) changes, forcing a
    /// fresh baseline per the protocol's progress-namespace rule.
    public func resetAll() async {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private func cursorKey(_ table: PushAppendTable, _ deviceId: String) -> String {
        keyPrefix + "cursor." + table.wireName + "." + deviceId
    }

    private func windowKey(_ table: PushMutableTable, _ deviceId: String) -> String {
        keyPrefix + "window." + table.wireName + "." + deviceId
    }

    private struct StoredCursor: Codable {
        let rowId: Int64
        let keySha256: String
    }

    private struct StoredWindow: Codable {
        let fromDay: String
        let toDay: String
        let startTs: Int64
        let endTs: Int64
        let batchId: String
        let dayHashes: [String: String]
    }
}
