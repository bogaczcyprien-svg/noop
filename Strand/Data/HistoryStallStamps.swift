import Foundation
import StrandAnalytics

/// FORK: the persisted inputs of `HistoryStallMonitor` — written by `BLEManager` at the end of every
/// history offload, read by the Today banner and the iOS notifier. On-device UserDefaults only.
enum HistoryStallStamps {
    static let lastBankedKey = "noop.historyStall.lastBankedTs"
    static let lastAttemptKey = "noop.historyStall.lastAttemptTs"
    static let firstEmptyKey = "noop.historyStall.firstEmptyTs"
    static let emptyCountKey = "noop.historyStall.emptyCount"

    static func recordOffload(banked: Bool, now: Date = Date()) {
        let d = UserDefaults.standard
        let ts = Int(now.timeIntervalSince1970)
        d.set(ts, forKey: lastAttemptKey)
        if banked {
            d.set(ts, forKey: lastBankedKey)
            d.removeObject(forKey: firstEmptyKey)
            d.set(0, forKey: emptyCountKey)
        } else {
            if d.object(forKey: firstEmptyKey) == nil { d.set(ts, forKey: firstEmptyKey) }
            d.set(d.integer(forKey: emptyCountKey) + 1, forKey: emptyCountKey)
        }
    }

    static func status(now: Date = Date()) -> HistoryStallMonitor.Status {
        let d = UserDefaults.standard
        return HistoryStallMonitor.evaluate(
            nowTs: Int(now.timeIntervalSince1970),
            lastBankedTs: d.object(forKey: lastBankedKey) as? Int,
            lastAttemptTs: d.object(forKey: lastAttemptKey) as? Int,
            firstEmptyTs: d.object(forKey: firstEmptyKey) as? Int,
            emptyCount: d.integer(forKey: emptyCountKey))
    }

    /// Start of the current empty run (what the notifier keys "already told the user" on).
    static var stallSinceTs: Int? {
        let d = UserDefaults.standard
        return (d.object(forKey: lastBankedKey) as? Int) ?? (d.object(forKey: firstEmptyKey) as? Int)
    }
}
