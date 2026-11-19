import Foundation

// RecoveryFactors.swift — "what moves my Charge?" from simple yes/no day habits.
// Fork addition (not upstream). Pure, deterministic, DB-free.
//
// For every habit (late workout, late meal, evening breathing, a Journal answer…) the days are split
// into "yes" and "no", and the mean NEXT-MORNING Charge of the two groups is compared. Deliberately
// simple and honest: a difference of means with a minimum count per side, never a causal claim. The
// screen reads it as "on days when…, your Charge is X points higher/lower on average".
public enum RecoveryFactors {

    public struct Day: Equatable, Sendable {
        public let day: String
        /// Charge of the morning AFTER this day's evening (0…100), nil when unknown.
        public let nextCharge: Double?
        /// Habit id → did it happen that day. A missing key means "unknown" and the day is skipped for it.
        public let flags: [String: Bool]
        public init(day: String, nextCharge: Double?, flags: [String: Bool]) {
            self.day = day; self.nextCharge = nextCharge; self.flags = flags
        }
    }

    public struct Factor: Equatable, Sendable {
        public let id: String
        public let yesMean: Double
        public let noMean: Double
        public let yesCount: Int
        public let noCount: Int
        /// yesMean − noMean, in Charge points (positive = the habit goes with a better Charge).
        public var delta: Double { yesMean - noMean }
    }

    public static let defaultMinEach = 3
    public static let defaultMinDelta = 3.0

    /// Factors with at least `minEach` days on each side and |delta| ≥ `minDelta`, strongest first.
    public static func analyse(_ days: [Day], minEach: Int = defaultMinEach,
                               minDelta: Double = defaultMinDelta) -> [Factor] {
        var ids = Set<String>()
        for d in days { ids.formUnion(d.flags.keys) }
        var out: [Factor] = []
        for id in ids.sorted() {
            var yes: [Double] = [], no: [Double] = []
            for d in days {
                guard let c = d.nextCharge, let f = d.flags[id] else { continue }
                if f { yes.append(c) } else { no.append(c) }
            }
            guard yes.count >= minEach, no.count >= minEach else { continue }
            let f = Factor(id: id, yesMean: mean(yes), noMean: mean(no),
                           yesCount: yes.count, noCount: no.count)
            if abs(f.delta) >= minDelta { out.append(f) }
        }
        return out.sorted { abs($0.delta) == abs($1.delta) ? $0.id < $1.id : abs($0.delta) > abs($1.delta) }
    }

    static func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }
}
