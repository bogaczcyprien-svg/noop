#if os(iOS)
import Foundation
import UserNotifications
import WhoopStore
import StrandAnalytics

/// Posts a once-per-streak LOCAL notification when HRV has sat clearly above or below the personal
/// baseline for several consecutive nights — a general "this is unusual for you lately" nudge,
/// distinct from the existing illness-signal engine (which needs a more specific multi-signal
/// pattern, not just one metric trending). Default OFF; no network. Fork addition.
@MainActor
public final class TrendNotifier {
    public static let shared = TrendNotifier()

    private let enabledKey = "noop.trendNotifier.enabled"
    private let lastNotifiedKey = "noop.trendNotifier.lastNotifiedDay"
    private let requestIdPrefix = "trend-"

    /// Consecutive nights the deviation must hold before notifying — one noisy night alone never fires.
    static let minStreakNights = 3
    /// Personal-sigma a night must clear, on the SAME side as the streak, to extend it.
    static let zThreshold = 1.0

    private var cachedStore: WhoopStore?
    private init() {}

    public var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Enable/disable. Enabling asks for notification permission if not yet determined, same shape as
    /// `SleepRecapNotifier.setEnabled`.
    public func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        guard on else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Call from the same post-offload hook as the other triggers. No-ops unless enabled, there's a
    /// qualifying streak as of the latest night, that night hasn't already been notified about, and
    /// notification permission is actually granted.
    public func postIfDue() async {
        guard isEnabled else { return }
        guard let store = await store() else { return }

        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        // 45 days: enough history for the HRV baseline to be more than freshly-seeded before a streak
        // is judged against it.
        guard let from = cal.date(byAdding: .day, value: -45, to: today) else { return }
        guard let days = try? await store.dailyMetrics(
            deviceId: Repository.whoopSource,
            from: PushDayFormat.formatter.string(from: from),
            to: PushDayFormat.formatter.string(from: today)
        ) else { return }
        let sorted = days.sorted { $0.day < $1.day }
        guard let latestDay = sorted.last(where: { $0.avgHrv != nil })?.day else { return }
        guard UserDefaults.standard.string(forKey: lastNotifiedKey) != latestDay else { return }
        guard let streak = Self.currentStreak(days: sorted), streak.count >= Self.minStreakNights else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }

        let direction = streak.aboveBaseline ? "au-dessus" : "en-dessous"
        let pct = Int((abs(streak.avgRatio) * 100).rounded())
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Tendance inhabituelle")
        content.body = "Votre HRV est ~\(pct)% \(direction) de d'habitude depuis \(streak.count) nuits."
        content.sound = .default
        let request = UNNotificationRequest(identifier: requestIdPrefix + latestDay,
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(latestDay, forKey: lastNotifiedKey)
    }

    struct Streak: Equatable { let count: Int; let aboveBaseline: Bool; let avgRatio: Double }

    /// Pure, testable: walks the HRV history building a rolling baseline (never peeking forward — each
    /// night is judged against the baseline AS OF BEFORE it, same incremental-fold discipline
    /// `RecoveryScorer` uses), then counts how many of the MOST RECENT nights sit clearly (±zThreshold)
    /// on the same side of that baseline. Returns nil when there's no current streak.
    static func currentStreak(days: [DailyMetric]) -> Streak? {
        let values = days.map { $0.avgHrv }
        guard !values.isEmpty else { return nil }

        var baselinesBefore: [BaselineState?] = []
        var state: BaselineState? = nil
        for v in values {
            baselinesBefore.append(state)
            state = Baselines.update(state, value: v, cfg: Baselines.hrvCfg)
        }

        var count = 0
        var aboveBaseline = true
        var ratioSum = 0.0
        for i in stride(from: values.count - 1, through: 0, by: -1) {
            guard let v = values[i], let b = baselinesBefore[i], b.usable else { break }
            let dev = Baselines.deviation(v, state: b)
            guard abs(dev.z) >= zThreshold else { break }
            let isAbove = dev.z > 0
            if count == 0 { aboveBaseline = isAbove }
            else if isAbove != aboveBaseline { break }
            count += 1
            ratioSum += dev.ratio
        }
        guard count > 0 else { return nil }
        return Streak(count: count, aboveBaseline: aboveBaseline, avgRatio: ratioSum / Double(count))
    }

    private func store() async -> WhoopStore? {
        if let cachedStore { return cachedStore }
        guard let path = try? StorePaths.defaultDatabasePath(),
              let opened = try? await WhoopStore(path: path)
        else { return nil }
        cachedStore = opened
        return opened
    }
}
#endif
