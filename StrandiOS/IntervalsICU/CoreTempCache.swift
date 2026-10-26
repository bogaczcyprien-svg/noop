#if os(iOS)
import Foundation
import StrandAnalytics

/// Per-activity CORE internal temperature for the intervals.icu activity cards (fork addition): the
/// average and highest value of the activity's `core_temperature` stream, keyed by the activity's
/// start. Kept in UserDefaults beside the other intervals.icu preferences rather than in the database:
/// it is a small display cache, rebuilt by the next import if it is ever lost.
enum CoreTempCache {
    private static let key = "noop.intervals.coreTemp"

    /// startTs → [avg, max]; an empty array records "checked, no CORE data".
    private static func load() -> [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    }

    static func isChecked(_ startTs: Int) -> Bool {
        load()[String(startTs)] != nil
    }

    static func save(_ summary: CoreTempStats.Summary?, startTs: Int) {
        var all = load()
        all[String(startTs)] = summary.map { [$0.avgC, $0.maxC] } ?? []
        UserDefaults.standard.set(all, forKey: key)
    }

    /// (average, highest) internal temperature, °C, for the activity starting at `startTs`.
    static func summary(_ startTs: Int) -> (avgC: Double, maxC: Double)? {
        guard let v = load()[String(startTs)], v.count == 2 else { return nil }
        return (v[0], v[1])
    }
}
#endif
