import Foundation
import UserNotifications
import WhoopStore

// MARK: - Overload alert (fork-only; symmetric counterpart to StrainTargetNotifier's #593 nudge)
//
// `StrainTargetNotifier` watches the LOW end of today's recovery-derived optimal strain band (#43) and
// celebrates reaching it. There was no signal at all for the opposite: Effort running ABOVE that band
// for several days running, which is the pattern that actually predicts overreaching. This is that
// signal — opt-in, default OFF like every other automation in this app.
//
// Fork-only addition: no Android twin, so there is no byte-identical-parity obligation the way
// StrainTargetNotifier has one. CLEAN-ROOM, same as its sibling: NOOP's own copy, NOOP's own band.
enum OverloadNotifier {
    private static let lastDayKey = "behavior.overloadLastDay"

    /// Pure, testable policy — no notification/UserDefaults runtime, so it can be pinned by a test the
    /// same way StrainTargetPolicy is.
    enum OverloadPolicy {
        /// How many consecutive days above band it takes to call it a pattern rather than one hard day.
        static let requiredStreak = 3

        /// A single day counts as overloaded when its Effort (0-21 coupled axis) lands STRICTLY above
        /// that day's OWN recovery-derived optimal band upper bound. Both inputs must be known — a nil
        /// band (calibrating / unscored recovery) is never counted as overloaded, same "never guess a
        /// target" rule as StrainTargetPolicy.
        static func isOverloaded(strain21: Double?, upperBound21: Int?) -> Bool {
            guard let strain21, let upperBound21 else { return false }
            return strain21 > Double(upperBound21)
        }

        /// The length of the most recent run of overloaded days, walking backward from the latest day
        /// in `days`. Stops at the first day that isn't overloaded (or the list runs out). Days are
        /// sorted descending here so the caller doesn't have to pre-sort its history.
        static func currentStreak(days: [(day: String, strain21: Double?, upperBound21: Int?)]) -> Int {
            var streak = 0
            for d in days.sorted(by: { $0.day > $1.day }) {
                guard isOverloaded(strain21: d.strain21, upperBound21: d.upperBound21) else { break }
                streak += 1
            }
            return streak
        }

        /// Fire at most once per day: only when enabled, the streak has reached the threshold, and we
        /// haven't already posted for `today`.
        static func shouldNotify(enabled: Bool, streak: Int, lastNotifiedDay: String?, today: String) -> Bool {
            guard enabled else { return false }
            return streak >= requiredStreak && lastNotifiedDay != today
        }

        /// Title + body for the warning. NOOP's OWN wording.
        static func copy(streakDays: Int) -> (title: String, body: String) {
            (String(localized: "Training load is running high"),
             String(localized: "Effort has landed above your optimal range for \(streakDays) days in a row. An easier day would let recovery catch up."))
        }
    }

    /// Ask up front (called when the user enables the alert), the BatteryNotifier/StrainTargetNotifier
    /// idiom, so the system dialog appears at a predictable moment rather than on the first streak.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Run the policy over the resolved daily history and post at most one notification per day.
    /// `today` is the resolved today-row's day key (the same logical-day resolution every dashboard
    /// surface uses); `days` is the full daily history the streak is measured over. No-op on every path
    /// that fails the policy, so the caller can fire this freely each time the day history republishes.
    static func onDaysUpdate(today: String, days: [DailyMetric], enabled: Bool) {
        let rows = days.map { d -> (day: String, strain21: Double?, upperBound21: Int?) in
            (d.day,
             d.strain.map { UnitFormatter.effortValue($0, scale: .whoop) },
             CoupledView.optimalStrainRange(recovery: d.recovery)?.upperBound)
        }
        let streak = OverloadPolicy.currentStreak(days: rows)
        let d = UserDefaults.standard
        guard OverloadPolicy.shouldNotify(enabled: enabled, streak: streak,
                                          lastNotifiedDay: d.string(forKey: lastDayKey),
                                          today: today) else { return }
        let copy = OverloadPolicy.copy(streakDays: streak)
        let center = UNUserNotificationCenter.current()
        // Authorization is requested once via requestAuthorization() when the toggle is enabled; here we
        // only check status (no second system prompt) — the BatteryNotifier idiom.
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = copy.title
            content.body = copy.body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "strain-overload", content: content, trigger: nil))
            UserDefaults.standard.set(today, forKey: lastDayKey)
        }
    }
}
