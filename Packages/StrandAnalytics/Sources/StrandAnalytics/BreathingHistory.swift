import Foundation

/// Breathing-tab session history (fork addition): what the iOS app keeps of each finished session, and
/// the progress figures read from it. Pure; the app stores the entries.
public enum BreathingHistory {

    /// One finished session. Figures are for the guided part unless named `free…`.
    public struct Entry: Codable, Equatable, Sendable {
        public let ts: Int
        public let exerciseId: String
        public let guidedSeconds: Int
        public let avgCoherence: Double?
        public let avgHR: Double?
        public let freeAvgHR: Double?
        public let rmssd: Double?
        public let breathsPerMin: Double?

        public init(ts: Int, exerciseId: String, guidedSeconds: Int, avgCoherence: Double?, avgHR: Double?,
                    freeAvgHR: Double?, rmssd: Double?, breathsPerMin: Double?) {
            self.ts = ts; self.exerciseId = exerciseId; self.guidedSeconds = guidedSeconds
            self.avgCoherence = avgCoherence; self.avgHR = avgHR; self.freeAvgHR = freeAvgHR
            self.rmssd = rmssd; self.breathsPerMin = breathsPerMin
        }

        /// Heart-rate change from free breathing to the exercise, bpm (negative = it came down).
        public var hrChange: Double? {
            guard let a = freeAvgHR, let b = avgHR else { return nil }
            return b - a
        }
    }

    /// Sessions shorter than this are not kept: too short to say anything.
    public static let minGuidedSeconds = 60
    /// How many sessions each side of the trend comparison.
    public static let trendWindow = 7
    /// Entries kept at most (oldest dropped first).
    public static let maxEntries = 500

    /// `entries` with `new` appended, oldest dropped past `maxEntries`. A too-short session is not added.
    public static func appending(_ new: Entry, to entries: [Entry]) -> [Entry] {
        guard new.guidedSeconds >= minGuidedSeconds else { return entries }
        let all = (entries + [new]).sorted { $0.ts < $1.ts }
        return Array(all.suffix(maxEntries))
    }

    /// Mean of `value` over the last `trendWindow` sessions that carry it, against the `trendWindow`
    /// before them. nil until both halves are full.
    public static func trend(_ entries: [Entry], _ value: (Entry) -> Double?) -> (recent: Double, previous: Double)? {
        let values = entries.sorted { $0.ts < $1.ts }.compactMap(value)
        guard values.count >= 2 * trendWindow else { return nil }
        let recent = values.suffix(trendWindow)
        let previous = values.dropLast(trendWindow).suffix(trendWindow)
        return (recent.reduce(0, +) / Double(recent.count), previous.reduce(0, +) / Double(previous.count))
    }

    /// Consecutive local days, ending today or yesterday, with at least one session.
    public static func streakDays(_ entries: [Entry], now: Date, calendar: Calendar) -> Int {
        let days = Set(entries.map { calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.ts))) })
        var day = calendar.startOfDay(for: now)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day), days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return count
    }

    /// Sessions in the 7 days ending at `now`.
    public static func sessionsLast7Days(_ entries: [Entry], now: Date) -> Int {
        let from = Int(now.timeIntervalSince1970) - 7 * 86_400
        return entries.filter { $0.ts > from && $0.ts <= Int(now.timeIntervalSince1970) }.count
    }
}
