#if os(iOS)
import Foundation
import UserNotifications

/// FORK-ONLY, not ported to Android. A local reminder every Sunday at 20:00 that the week in review is
/// ready; tapping it opens `WeeklyRecapView` (routed by `NotificationPresenter`). On by default, since
/// it was asked for; it never prompts for permission on its own, only when switched on from the recap.
/// No network, no data in the notification: the numbers are on the screen it opens.
enum WeeklyRecapNotifier {
    static let categoryId = "noop.weeklyRecap"
    private static let requestId = "weekly-recap-sunday"
    private static let enabledKey = "noop.weeklyRecap.enabled"

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        let center = UNUserNotificationCenter.current()
        if on {
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                if granted { schedule() }
            }
        } else {
            center.removePendingNotificationRequests(withIdentifiers: [requestId])
        }
    }

    /// At launch: (re)arm the weekly reminder when it is on and notifications are already allowed.
    static func scheduleIfEnabled() {
        guard isEnabled else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            guard s.authorizationStatus == .authorized || s.authorizationStatus == .provisional else { return }
            schedule()
        }
    }

    private static func schedule() {
        let content = UNMutableNotificationContent()
        content.title = "Ton bilan de la semaine est prêt"
        content.body = "Sommeil, Charge, entraînement, respiration et nutrition : touche pour voir ta semaine."
        content.sound = .default
        content.categoryIdentifier = categoryId
        var when = DateComponents()
        when.weekday = 1   // Sunday
        when.hour = 20
        when.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: requestId, content: content, trigger: trigger))
    }
}
#endif
