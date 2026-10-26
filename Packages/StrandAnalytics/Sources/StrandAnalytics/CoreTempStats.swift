import Foundation

/// Average and highest internal body temperature over a recorded CORE stream (fork addition). Pure.
///
/// Fed the `core_temperature` stream intervals.icu keeps for an activity a head unit recorded with a
/// CORE sensor: one value per sample, nulls where the sensor sent nothing. Values outside a living
/// body's range (a sensor off the body, a decode glitch) are left out rather than averaged in.
public enum CoreTempStats {

    public struct Summary: Equatable, Sendable {
        public let avgC: Double
        public let maxC: Double
        public let samples: Int
    }

    /// Plausible internal temperatures, °C.
    public static let plausibleC: ClosedRange<Double> = 34.0...43.0
    /// Fewest valid samples worth summarising.
    public static let minSamples = 10

    public static func summary(_ values: [Double?]) -> Summary? {
        let ok = values.compactMap { $0 }.filter { plausibleC.contains($0) }
        guard ok.count >= minSamples, let maxC = ok.max() else { return nil }
        return Summary(avgC: ok.reduce(0, +) / Double(ok.count), maxC: maxC, samples: ok.count)
    }
}
