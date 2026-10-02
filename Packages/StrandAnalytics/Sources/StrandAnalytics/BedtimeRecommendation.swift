import Foundation

// BedtimeRecommendation.swift — a tonight bedtime suggestion from sleep debt + habitual wake time.
// Fork addition (not upstream). Pure, deterministic, DB-free, same shape as SleepDebt/CircadianEngine.
//
// WELLNESS / BEHAVIOURAL AWARENESS ONLY. A planning suggestion, never a prescription: it never
// accounts for tomorrow's actual obligations (an early meeting the user hasn't told it about), so the
// surface must read as "aim for" rather than a command.
public enum BedtimeRecommendation {

    public struct Result: Equatable, Sendable {
        /// Suggested bedtime, minutes since local midnight (0..<1440).
        public let bedtimeMinutes: Int
        /// Total sleep this is aiming for tonight (minutes): base need + debt owed.
        public let targetSleepMin: Double
        /// Minutes of debt this target would pay down (0 when there is none owed).
        public let debtOwedMin: Double
        public init(bedtimeMinutes: Int, targetSleepMin: Double, debtOwedMin: Double) {
            self.bedtimeMinutes = bedtimeMinutes
            self.targetSleepMin = targetSleepMin
            self.debtOwedMin = debtOwedMin
        }
    }

    /// Cap on how much a single night's target stretches to repay debt, so one very short night never
    /// demands an unreasonable catch-up bedtime. Mirrors `SleepDebt.debtCarryFactor`'s spirit: pay some
    /// of it down, not all of it, in one night.
    public static let maxDebtRepayMin: Double = 60

    /// - Parameters:
    ///   - debtBalanceMin: `SleepDebtLedger.balanceMin` (negative = owed, 0 = on target; never positive).
    ///   - baseNeedMin: personal sleep need in minutes (`AnalyticsEngine.Rest.defaultNeedHours * 60` by
    ///     default, or the user's own override).
    ///   - habitualWakeMinutes: typical wake clock-time, minutes since local midnight (the caller
    ///     derives this however it already does — e.g. an average of recent sessions' end times).
    public static func recommend(debtBalanceMin: Double, baseNeedMin: Double,
                                 habitualWakeMinutes: Int) -> Result {
        let owed = min(maxDebtRepayMin, max(0, -debtBalanceMin))
        let targetMin = baseNeedMin + owed
        let raw = habitualWakeMinutes - Int(targetMin.rounded())
        let bedtime = ((raw % 1_440) + 1_440) % 1_440
        return Result(bedtimeMinutes: bedtime, targetSleepMin: targetMin, debtOwedMin: owed)
    }

    /// `bedtimeMinutes` as "HH:mm", for a caller that wants plain text without pulling in DateFormatter
    /// state (e.g. a notification body built off-main). Always 24h; the UI layer applies locale/12h
    /// formatting itself where that matters.
    public static func formatClock(_ minutesSinceMidnight: Int) -> String {
        let m = ((minutesSinceMidnight % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}
