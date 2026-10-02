#if os(iOS)
import Foundation
import UserNotifications
import WhoopStore

/// Posts a once-per-workout LOCAL notification shortly after a session ends, suggesting the
/// post-workout nutrition window — no food database, no logging, just a timing nudge. Default OFF;
/// no network. Fork addition.
@MainActor
public final class WorkoutNutritionNotifier {
    public static let shared = WorkoutNutritionNotifier()

    private let enabledKey = "noop.workoutNutrition.enabled"
    private let lastNotifiedKey = "noop.workoutNutrition.lastNotifiedEndTs"
    private let requestIdPrefix = "workout-nutrition-"

    /// Only notify for a workout that ended within this many minutes of now — a workout found while
    /// catching up on an old sync shouldn't trigger a stale "eat now" nudge.
    static let recencyWindowMin = 90

    private var cachedStore: WhoopStore?
    private init() {}

    public var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    public func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        guard on else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Call from the same post-offload hook as the other triggers. No-ops unless enabled, there's a
    /// workout that ended recently and hasn't already been notified about, and permission is granted.
    public func postIfDue() async {
        guard isEnabled else { return }
        guard let store = await store() else { return }

        let now = Int(Date().timeIntervalSince1970)
        guard let workouts = try? await store.workouts(
            deviceId: Repository.whoopSource, from: now - 2 * 86_400, to: now, limit: 10
        ), let latest = workouts.max(by: { $0.endTs < $1.endTs }) else { return }

        guard now - latest.endTs <= Self.recencyWindowMin * 60 else { return }
        guard UserDefaults.standard.integer(forKey: lastNotifiedKey) != latest.endTs else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Après l'effort")
        content.body = "Séance terminée — pensez à manger et à vous hydrater dans l'heure qui suit."
        content.sound = .default
        let request = UNNotificationRequest(identifier: requestIdPrefix + "\(latest.endTs)",
                                            content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(latest.endTs, forKey: lastNotifiedKey)
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
