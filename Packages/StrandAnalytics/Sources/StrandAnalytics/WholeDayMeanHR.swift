import Foundation

/// The arithmetic mean heart rate across a WHOLE calendar/logical day — unlike
/// `PrimarySessionRestingHR` (the longest SLEEP session only), this averages every HR reading in the
/// day's window, so it includes waking hours as well as the night.
///
/// Takes `[Double]` rather than `[Int]` bpm so it can be fed either raw per-sample bpm (an `Int` reading
/// widens trivially) or already-bucketed mean bpm (e.g. `Repository.hrBuckets`'s 5-minute bucket
/// means) without the caller doing its own conversion or a second implementation existing for each.
///
/// Twin of Kotlin `WholeDayMeanHR`. Keep byte-identical — unlike most of this session's Nutrition
/// work, a per-day stored HR metric is exactly what the cross-platform parity contract covers.
public enum WholeDayMeanHR {

    /// The worn-HR range `PrimarySessionRestingHR`/`AnalyticsEngine` use when deciding a sample is
    /// real — reused so validity is one rule across every HR-mean computation in this package.
    public static let defaultValidBpm: ClosedRange<Double> = 30...220
    /// Minimum valid readings before a mean is returned, rather than reporting one off a near-empty
    /// window. Same floor `PrimarySessionRestingHR` uses.
    public static let defaultMinValidSamples = 30

    /// Mean of the valid (`validBpm`) readings in `bpm`, or `nil` when fewer than `minValidSamples`
    /// clear that range — never a mean computed off too little of the day to mean anything.
    public static func mean(bpm: [Double],
                            validBpm: ClosedRange<Double> = defaultValidBpm,
                            minValidSamples: Int = defaultMinValidSamples) -> Double? {
        let valid = bpm.filter { validBpm.contains($0) }
        guard valid.count >= minValidSamples else { return nil }
        return valid.reduce(0, +) / Double(valid.count)
    }
}
