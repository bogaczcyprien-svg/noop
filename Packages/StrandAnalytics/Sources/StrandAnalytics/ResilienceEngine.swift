import Foundation

// ResilienceEngine.swift — fork addition (not upstream). Answers one question, in the spirit of
// Oura's Resilience score: "on your more stressful days, how well did you still recover?" Built
// entirely from two metrics NOOP already stores daily (`stress`, `recovery`/Charge) — no new engine,
// no new sensor, a composite READ of existing series.
public enum ResilienceEngine {
    public struct DayInput: Equatable, Sendable {
        public let day: String
        public let stress: Double?      // NOOP's stored "stress" series, 0...3
        public let recovery: Double?    // Charge, 0...100
        public init(day: String, stress: Double?, recovery: Double?) {
            self.day = day; self.stress = stress; self.recovery = recovery
        }
    }

    public enum Band: String, Equatable, Sendable {
        case limited, adequate, solid, strong, exceptional
    }

    public struct Result: Equatable, Sendable {
        /// Mean Charge on the higher-stress days in the window — the headline number.
        public let resilienceScore: Double
        public let band: Band
        /// How many of the window's days qualified as "higher stress" and had a same-day Charge.
        public let higherStressDayCount: Int
        public init(resilienceScore: Double, band: Band, higherStressDayCount: Int) {
            self.resilienceScore = resilienceScore; self.band = band
            self.higherStressDayCount = higherStressDayCount
        }
    }

    public static let defaultWindowDays = 14
    /// Minimum qualifying days before a read is offered — fewer than this and a single rough day would
    /// swing the whole number.
    public static let minQualifyingDays = 4
    /// A day counts as "higher stress" at/above this stored stress level (the stored series is 0...3;
    /// 2 is the "high" band already used elsewhere in the app for this same series).
    public static let higherStressThreshold = 2.0

    /// `days` in any order; only the trailing `window` days (by `day` string, sorted) are considered.
    /// Returns nil when fewer than `minQualifyingDays` days both cleared the stress threshold AND had
    /// a same-day Charge value — an honest "not enough data yet" rather than a noisy early number.
    public static func evaluate(days: [DayInput], window: Int = defaultWindowDays) -> Result? {
        let trailing = days.sorted { $0.day < $1.day }.suffix(window)
        let qualifying = trailing.compactMap { d -> Double? in
            guard let s = d.stress, s >= higherStressThreshold, let r = d.recovery else { return nil }
            return r
        }
        guard qualifying.count >= minQualifyingDays else { return nil }
        let mean = qualifying.reduce(0, +) / Double(qualifying.count)
        return Result(resilienceScore: mean, band: band(for: mean), higherStressDayCount: qualifying.count)
    }

    /// Band thresholds on the SAME 0...100 scale Charge already uses, so "Solid" resilience roughly
    /// lines up with "Charge holds up even on stressful days" — not a separate scale to learn.
    static func band(for score: Double) -> Band {
        switch score {
        case ..<34: return .limited
        case ..<50: return .adequate
        case ..<67: return .solid
        case ..<85: return .strong
        default: return .exceptional
        }
    }
}
