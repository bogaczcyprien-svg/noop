import Foundation

// EarlyNightRecovery.swift — fork addition (not upstream), in the spirit of Polar's Nightly Recharge
// "ANS charge" idea: how did the FIRST part of the night's autonomic recovery compare to the whole
// night? Pure, DB-free — the caller supplies already-fetched NN intervals split at the window
// boundary; this file only does the HRV math (reusing `HRVAnalyzer.rmssdRaw`, no new HRV model).
public enum EarlyNightRecovery {
    /// Minutes from sleep onset the "early window" covers. 4h mirrors the concept this is inspired by;
    /// not tied to any particular physiological boundary (deep sleep concentration varies by person).
    public static let earlyWindowMinutes = 240
    /// Minimum NN intervals required in EACH window before a comparison is offered — too few points
    /// make RMSSD noisy to the point of being misleading.
    public static let minIntervalsPerWindow = 30

    public struct Result: Equatable, Sendable {
        /// RMSSD (ms) over the first `earlyWindowMinutes` of sleep.
        public let earlyRMSSD: Double
        /// RMSSD (ms) over the full night.
        public let fullNightRMSSD: Double
        /// `earlyRMSSD / fullNightRMSSD` — > 1 means the early night ran HIGHER (parasympathetic
        /// recovery front-loaded); < 1 means it built through the night instead.
        public let ratio: Double
        public init(earlyRMSSD: Double, fullNightRMSSD: Double) {
            self.earlyRMSSD = earlyRMSSD
            self.fullNightRMSSD = fullNightRMSSD
            self.ratio = fullNightRMSSD > 0 ? earlyRMSSD / fullNightRMSSD : 1.0
        }
    }

    /// `earlyNN` / `fullNightNN`: NN intervals (ms) already filtered to [sessionStart, sessionStart +
    /// earlyWindowMinutes] and the full session respectively. Returns nil when either window has fewer
    /// than `minIntervalsPerWindow` intervals — an honest "not enough signal" rather than a noisy ratio.
    public static func evaluate(earlyNN: [Double], fullNightNN: [Double]) -> Result? {
        guard earlyNN.count >= minIntervalsPerWindow, fullNightNN.count >= minIntervalsPerWindow,
              let early = HRVAnalyzer.rmssdRaw(earlyNN),
              let full = HRVAnalyzer.rmssdRaw(fullNightNN)
        else { return nil }
        return Result(earlyRMSSD: early, fullNightRMSSD: full)
    }
}
