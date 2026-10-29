import Foundation

/// Today-screen Key Metrics verdict (fork addition, iOS only, not ported to Android): says whether a
/// tile's number is good or not, in place of the fill bar that only showed the number against a fixed
/// ceiling.
///
/// Two kinds of read-out:
/// - `zone`: a score with its own fixed bands (Recovery 67/34, Rest 85/70), the WHOOP-style green,
///   yellow and red zones.
/// - `relative`: the value against the wearer's own usual, the mean of the prior days' values. Inside
///   ±`normalZ` spreads it reads normal; past `strongZ` it is "well" above or below. `rule` says which
///   way is good: higher HRV is good, a higher resting HR is not, and respiration or skin temperature
///   moving either way is worth a look.
///
/// Presentation only: nothing here feeds a score.
public enum KeyMetricVerdict {

    /// Which way of moving is good for a metric.
    public enum Rule: Sendable {
        case higherIsBetter
        case lowerIsBetter
        /// Either direction away from usual is worth a look (respiration, skin temperature).
        case steadyIsBetter
        /// Only a drop is worth a look; above usual is just normal (blood oxygen).
        case lowIsBad
        /// Neither direction is good or bad (steps, calories, effort): the read-out only says which way.
        case neither
    }

    public enum Tone: Sendable, Equatable { case good, normal, watch, off, neutral }
    public enum Direction: Sendable, Equatable { case above, below, inline }

    public struct Reading: Sendable, Equatable {
        public let tone: Tone
        public let direction: Direction
        /// Beyond `strongZ` spreads from usual (relative read-outs only).
        public let strong: Bool
        /// The wearer's usual value, for relative read-outs.
        public let usual: Double?

        public init(tone: Tone, direction: Direction, strong: Bool, usual: Double?) {
            self.tone = tone
            self.direction = direction
            self.strong = strong
            self.usual = usual
        }
    }

    /// Prior days needed before a usual exists.
    public static let minHistory = 7
    /// Within this many spreads of usual reads normal.
    public static let normalZ = 0.5
    /// Beyond this many spreads reads "well" above or below.
    public static let strongZ = 1.5

    /// The wearer's usual: the mean of the prior days, or nil below `minHistory` days.
    public static func usual(_ history: [Double]) -> Double? {
        let values = history.filter(\.isFinite)
        guard values.count >= minHistory else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// `value` against the mean and spread of `history`. `minSpread` floors the spread, in the metric's
    /// own unit, so a very steady history does not turn a trivial change into a "well above".
    public static func relative(value: Double?, history: [Double], rule: Rule, minSpread: Double) -> Reading? {
        guard let value, value.isFinite, let mean = usual(history) else { return nil }
        let values = history.filter(\.isFinite)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let spread = max(variance.squareRoot(), minSpread)
        let z = spread > 0 ? (value - mean) / spread : 0
        let direction: Direction = z >= normalZ ? .above : (z <= -normalZ ? .below : .inline)
        let strong = abs(z) >= strongZ
        let worse: Tone = strong ? .off : .watch
        let tone: Tone
        switch (direction, rule) {
        case (.inline, _): tone = .normal
        case (_, .neither): tone = .neutral
        case (.above, .higherIsBetter), (.below, .lowerIsBetter): tone = .good
        case (.above, .lowIsBad): tone = .normal
        default: tone = worse
        }
        return Reading(tone: tone, direction: direction, strong: strong, usual: mean)
    }

    /// A score against its fixed bands: green from `greenFrom`, yellow from `yellowFrom`, red below.
    public static func zone(value: Double?, greenFrom: Double, yellowFrom: Double) -> Reading? {
        guard let value, value.isFinite else { return nil }
        if value >= greenFrom { return Reading(tone: .good, direction: .above, strong: false, usual: nil) }
        if value >= yellowFrom { return Reading(tone: .watch, direction: .inline, strong: false, usual: nil) }
        return Reading(tone: .off, direction: .below, strong: false, usual: nil)
    }

    /// Recovery (Charge, %) bands.
    public static func recovery(_ pct: Double?) -> Reading? { zone(value: pct, greenFrom: 67, yellowFrom: 34) }
    /// Rest (sleep performance, %) bands.
    public static func rest(_ pct: Double?) -> Reading? { zone(value: pct, greenFrom: 85, yellowFrom: 70) }
}
