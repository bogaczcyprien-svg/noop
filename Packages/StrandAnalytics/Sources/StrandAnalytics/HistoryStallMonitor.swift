import Foundation

// HistoryStallMonitor.swift — decides whether the strap has stopped handing over its banked history.
// Fork addition (not upstream). Pure, deterministic, DB-free.
//
// The failure it watches for: live heart rate keeps streaming (so the app looks fine) while every
// history offload comes back empty — what a firmware update or a membership lock looks like from the
// app's side. A healthy strap banks new rows on essentially every sync, so a run of empty offloads
// spanning more than a day and a half, while the strap is demonstrably connected, is worth telling the
// user about. A strap that simply was not near the phone is NOT a stall (no recent offload attempt).
public enum HistoryStallMonitor {

    public enum Status: Equatable, Sendable {
        /// History is flowing (or there is not yet enough evidence to say otherwise).
        case ok
        /// No offload was attempted recently — the strap is not connected, so nothing can be concluded.
        case notConnected
        /// Offloads keep running but none has banked anything for `hours` hours.
        case stalled(hours: Int)
    }

    /// Hours without a banking offload before a stall is reported.
    public static let stallHours = 36
    /// An offload attempt must be this recent for the strap to count as connected.
    public static let recentAttemptHours = 6
    /// Minimum consecutive empty offloads, so one slow wake-up after a long gap never alarms.
    public static let minEmptyOffloads = 3

    /// - Parameters:
    ///   - nowTs: current unix time (s).
    ///   - lastBankedTs: last offload that persisted sensor rows, nil if never seen.
    ///   - lastAttemptTs: last offload attempt of any outcome, nil if never seen.
    ///   - firstEmptyTs: first empty offload since the last banking one, nil if none.
    ///   - emptyCount: consecutive empty offloads since the last banking one.
    public static func evaluate(nowTs: Int, lastBankedTs: Int?, lastAttemptTs: Int?,
                                firstEmptyTs: Int?, emptyCount: Int) -> Status {
        guard let attempt = lastAttemptTs, nowTs - attempt <= recentAttemptHours * 3_600 else {
            return .notConnected
        }
        guard emptyCount >= minEmptyOffloads, let since = lastBankedTs ?? firstEmptyTs else { return .ok }
        let hours = max(0, nowTs - since) / 3_600
        return hours >= stallHours ? .stalled(hours: hours) : .ok
    }
}
