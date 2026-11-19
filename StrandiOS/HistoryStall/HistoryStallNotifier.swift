#if os(iOS)
import Foundation
import UserNotifications
import StrandAnalytics

/// FORK-ONLY, not ported to Android. Tells the user once when the strap keeps connecting but has stopped
/// handing over its history (`HistoryStallMonitor`) — the symptom of a firmware update or a membership
/// lock. One notification per stall episode (keyed on the episode's start), on by default since it was
/// asked for; never prompts for permission by itself. Local only.
enum HistoryStallNotifier {
    private static let notifiedSinceKey = "noop.historyStall.notifiedSinceTs"

    static func checkIfDue() async {
        guard case .stalled(let hours) = HistoryStallStamps.status(),
              let since = HistoryStallStamps.stallSinceTs else { return }
        let d = UserDefaults.standard
        guard (d.object(forKey: notifiedSinceKey) as? Int) != since else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }
        let content = UNMutableNotificationContent()
        content.title = "L'historique de ta WHOOP ne passe plus"
        content.body = "Le bracelet est connecté mais ne donne plus son historique depuis \(hours) h. "
            + "Exporte le journal du bracelet (Appareils) pour qu'on regarde."
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "history-stall-\(since)", content: content, trigger: nil))
        d.set(since, forKey: notifiedSinceKey)
    }
}
#endif
