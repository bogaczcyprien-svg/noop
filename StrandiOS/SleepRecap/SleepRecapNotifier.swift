#if os(iOS)
import Foundation
import UserNotifications
import WhoopStore

/// Posts a once-per-day LOCAL notification summarizing last night's sleep (phases, duration,
/// efficiency, Charge) as soon as that night's data has finished computing — naturally lands "each
/// morning" once the strap/phone has synced, without a fixed-clock scheduler. Default OFF like every
/// NOOP automation; no server, no network, purely a local notification built from data already
/// computed and stored on-device. Fork addition.
@MainActor
public final class SleepRecapNotifier {
    public static let shared = SleepRecapNotifier()

    private let enabledKey = "noop.sleepRecap.enabled"
    private let lastPostedKey = "noop.sleepRecap.lastPostedDay"
    private let requestIdPrefix = "sleep-recap-"

    private var cachedStore: WhoopStore?

    private init() {}

    public var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Enable/disable. Enabling asks for notification permission if not yet determined — mirrors the
    /// authorization-gating shape `CoachBriefScheduler.setEnabled` already uses elsewhere in the app.
    public func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        guard on else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// Call from the same post-offload hook as the self-hosted / intervals.icu push triggers. No-ops
    /// unless enabled, there is a finalized night newer than the last one notified about, and
    /// notification permission is actually granted.
    public func postIfDue() async {
        guard isEnabled else { return }
        guard let store = await store() else { return }

        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        guard let from = cal.date(byAdding: .day, value: -2, to: today) else { return }
        guard let days = try? await store.dailyMetrics(
            deviceId: Repository.whoopSource,
            from: PushDayFormat.formatter.string(from: from),
            to: PushDayFormat.formatter.string(from: today)
        ) else { return }
        guard let latest = days.sorted(by: { $0.day < $1.day })
            .last(where: { $0.totalSleepMin != nil }) else { return }
        guard UserDefaults.standard.string(forKey: lastPostedKey) != latest.day else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Votre nuit")
        content.body = Self.summary(for: latest)
        content.sound = .default
        let request = UNNotificationRequest(identifier: requestIdPrefix + latest.day,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(latest.day, forKey: lastPostedKey)
    }

    /// Pure, testable: a one-line sleep-phase recap from a `DailyMetric`. Missing fields are simply
    /// omitted rather than shown as a misleading "0".
    static func summary(for metric: DailyMetric) -> String {
        var parts: [String] = []
        if let total = metric.totalSleepMin { parts.append(formatDuration(total)) }
        if let eff = metric.efficiency { parts.append("\(Int((eff * 100).rounded()))% efficacité") }
        var phases: [String] = []
        if let deep = metric.deepMin { phases.append("profond \(formatDuration(deep))") }
        if let rem = metric.remMin { phases.append("REM \(formatDuration(rem))") }
        if let light = metric.lightMin { phases.append("léger \(formatDuration(light))") }
        if !phases.isEmpty { parts.append(phases.joined(separator: ", ")) }
        if let recovery = metric.recovery { parts.append("Charge \(Int(recovery.rounded()))%") }
        return parts.isEmpty ? "Résumé de la nuit disponible dans NOOP." : parts.joined(separator: " — ")
    }

    private static func formatDuration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m)min"
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
