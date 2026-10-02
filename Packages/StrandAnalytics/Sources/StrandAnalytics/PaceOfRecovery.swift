import Foundation

// PaceOfRecovery.swift — fork addition (not upstream). A forward PROJECTION, not a measurement: "if
// you took it easy starting today, how many days until TrainingLoadEngine's TSB (form) would climb
// back to balanced (0)?" Reuses TrainingLoadEngine's own CTL/ATL state and decay constants — no new
// model, just an analytic continuation of the SAME exponential decay the engine already runs, assuming
// zero further load from today onward (the honest, clearly-labeled best case, not a prediction).
public enum PaceOfRecovery {
    public struct Projection: Equatable, Sendable {
        /// Days from today until TSB (CTL - ATL) would reach `targetTSB`, assuming no further
        /// training load. 0 when already there or past it.
        public let daysToRecovered: Int
        /// Today's TSB, for display alongside the projection.
        public let currentTSB: Double
        public init(daysToRecovered: Int, currentTSB: Double) {
            self.daysToRecovered = daysToRecovered
            self.currentTSB = currentTSB
        }
    }

    /// TSB a caller treats as "balanced" / recovered. 0 is the classic Banister-model convention (CTL
    /// == ATL); NOOP already uses 0 as TSB's own zero point, so no new threshold concept is introduced.
    public static let targetTSB: Double = 0
    /// Hard cap on the projection so a very deep trough reads "20+ days" rather than a false-precise
    /// huge number — the exponential model is a rough guide this far out, not a forecast.
    public static let maxProjectedDays: Int = 21

    /// - Parameters:
    ///   - ctl: today's chronic load (`TrainingLoadEngine.Result.ctl`).
    ///   - atl: today's acute load (`TrainingLoadEngine.Result.atl`).
    ///   - chronicTimeConstantDays / acuteTimeConstantDays: MUST match whatever
    ///     `TrainingLoadEngine.Configuration` produced `ctl`/`atl`, so the projection decays on the
    ///     same curve the displayed CTL/ATL came from.
    public static func project(ctl: Double, atl: Double,
                               chronicTimeConstantDays: Double = TrainingLoadEngine.Configuration.standard.chronicTimeConstantDays,
                               acuteTimeConstantDays: Double = TrainingLoadEngine.Configuration.standard.acuteTimeConstantDays
    ) -> Projection {
        let tsbNow = ctl - atl
        guard tsbNow < targetTSB else { return Projection(daysToRecovered: 0, currentTSB: tsbNow) }

        for day in 1...maxProjectedDays {
            let k = Double(day)
            let ctlK = ctl * exp(-k / chronicTimeConstantDays)
            let atlK = atl * exp(-k / acuteTimeConstantDays)
            if ctlK - atlK >= targetTSB {
                return Projection(daysToRecovered: day, currentTSB: tsbNow)
            }
        }
        return Projection(daysToRecovered: maxProjectedDays, currentTSB: tsbNow)
    }
}
