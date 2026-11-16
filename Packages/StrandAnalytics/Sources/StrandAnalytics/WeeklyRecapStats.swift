import Foundation
import WhoopStore

// WeeklyRecapStats.swift — FORK-ONLY, not ported to Android. The training and sleep parts of the iOS
// "week in review" (the Charge / Effort / Rest / HRV / RHR part is `WeeklyDigestEngine`). Pure: the
// caller passes the local day of each session, so no time zone is read here.
public enum WeeklyRecapStats {

    /// Monday-to-Sunday day keys of the week containing `day` ("yyyy-MM-dd"); empty if unparseable.
    public static func weekDays(containing day: String) -> [String] {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: day) else { return [] }
        return (0..<7).map { WeeklyDigestEngine.addDays(monday, $0) }
    }

    public struct Sport: Equatable, Sendable {
        public let name: String
        public let count: Int
        public let minutes: Double
    }

    public struct Training: Equatable, Sendable {
        public let count: Int
        public let minutes: Double
        public let distanceKm: Double
        /// Most minutes first.
        public let bySport: [Sport]
    }

    /// Sessions whose local start day (`dayOf(startTs)`) falls in `week`. Duration falls back to the
    /// session span when the row carries none.
    public static func training(_ rows: [WorkoutRow], week: Set<String>, dayOf: (Int) -> String) -> Training {
        let inWeek = rows.filter { week.contains(dayOf($0.startTs)) }
        func minutes(_ r: WorkoutRow) -> Double { (r.durationS ?? Double(r.endTs - r.startTs)) / 60 }
        var bySport: [String: (count: Int, minutes: Double)] = [:]
        for r in inWeek {
            let cur = bySport[r.sport] ?? (0, 0)
            bySport[r.sport] = (cur.count + 1, cur.minutes + minutes(r))
        }
        let sports = bySport.map { Sport(name: $0.key, count: $0.value.count, minutes: $0.value.minutes) }
            .sorted { $0.minutes != $1.minutes ? $0.minutes > $1.minutes : $0.name < $1.name }
        return Training(count: inWeek.count,
                        minutes: inWeek.reduce(0) { $0 + minutes($1) },
                        distanceKm: inWeek.reduce(0) { $0 + ($1.distanceM ?? 0) } / 1_000,
                        bySport: sports)
    }

    public struct Sleep: Equatable, Sendable {
        public let nights: Int
        public let avgMinutes: Double
        /// 0-1 when the nights carry one.
        public let avgEfficiency: Double?
    }

    /// Average sleep over the week's nights that have a duration; nil when none do.
    public static func sleep(minutesByDay: [String: Double], efficiencyByDay: [String: Double],
                             week: Set<String>) -> Sleep? {
        let mins = week.compactMap { minutesByDay[$0] }.filter { $0 > 0 }
        guard !mins.isEmpty else { return nil }
        let effs = week.compactMap { efficiencyByDay[$0] }
        return Sleep(nights: mins.count, avgMinutes: mins.reduce(0, +) / Double(mins.count),
                     avgEfficiency: effs.isEmpty ? nil : effs.reduce(0, +) / Double(effs.count))
    }
}
