#if os(iOS)
import Foundation
import UserNotifications
import WhoopStore
import StrandAnalytics

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
        // 16 days back: enough trailing nights for SleepDebt's 14-night window once today's partial
        // day is excluded, same margin AnalyticsEngine callers use elsewhere for this ledger.
        guard let from = cal.date(byAdding: .day, value: -16, to: today) else { return }
        guard let days = try? await store.dailyMetrics(
            deviceId: Repository.whoopSource,
            from: PushDayFormat.formatter.string(from: from),
            to: PushDayFormat.formatter.string(from: today)
        ) else { return }
        let sorted = days.sorted { $0.day < $1.day }
        guard let latest = sorted.last(where: { $0.totalSleepMin != nil }) else { return }
        guard UserDefaults.standard.string(forKey: lastPostedKey) != latest.day else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }

        var body = Self.summary(for: latest)
        if let bedtime = await bedtimeLine(store: store, days: sorted) {
            body += "\n" + bedtime
        }
        if let alarm = await alarmQualityLine(store: store, day: latest.day) {
            body += "\n" + alarm
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Votre nuit")
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: requestIdPrefix + latest.day,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(latest.day, forKey: lastPostedKey)
    }

    /// Tonight's bedtime suggestion (sleep debt + habitual wake time), as a notification line, or nil
    /// when there isn't enough recent data to say anything honest.
    private func bedtimeLine(store: WhoopStore, days: [DailyMetric]) async -> String? {
        let series = days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) }
        let ledger = SleepDebt.ledger(series: series)
        guard ledger.nightCount > 0 else { return nil }

        let now = Int(Date().timeIntervalSince1970)
        let weekAgo = now - 7 * 86_400
        guard let sessions = try? await store.sleepSessions(
            deviceId: Repository.whoopSource, from: weekAgo, to: now, limit: 20
        ), !sessions.isEmpty else { return nil }

        let tz = TimeZone.current.secondsFromGMT()
        // Average wake clock-minute across recent sessions. Averaging raw minutes-since-midnight is
        // fine here (not circular-mean) — a habitual wake routine doesn't straddle midnight in practice.
        let wakeMinutes = sessions.map { (($0.endTs + tz) % 86_400 + 86_400) % 86_400 / 60 }
        let habitualWake = wakeMinutes.reduce(0, +) / wakeMinutes.count

        let rec = BedtimeRecommendation.recommend(
            debtBalanceMin: ledger.balanceMin,
            baseNeedMin: AnalyticsEngine.Rest.defaultNeedHours * 60,
            habitualWakeMinutes: habitualWake
        )
        let clock = BedtimeRecommendation.formatClock(rec.bedtimeMinutes)
        if rec.debtOwedMin > 0 {
            return "Ce soir, visez un coucher vers \(clock) (inclut \(Int(rec.debtOwedMin.rounded()))min de dette de sommeil)."
        }
        return "Ce soir, visez un coucher vers \(clock)."
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

    /// INSTRUMENTATION ONLY (see `AlarmWakeQuality`'s header): reports what stage the already-fixed
    /// smart-alarm time landed in for the night ending `day`, if the alarm is enabled and that night's
    /// session covers it. Never changes when or whether the strap buzzes.
    private func alarmQualityLine(store: WhoopStore, day: String) async -> String? {
        guard UserDefaults.standard.bool(forKey: "behavior.smartAlarmEnabled") else { return nil }
        let alarmMinutes = UserDefaults.standard.object(forKey: "behavior.smartAlarmMinutes") as? Int
            ?? 7 * 60

        // `postIfDue()` only reaches here for the freshest finalized night, so the most recent session
        // by end time (within a generous 2-day window, well clear of `day`'s own ±4h logical-day
        // rollover) IS that night — no day-string matching needed.
        let now = Int(Date().timeIntervalSince1970)
        guard let sessions = try? await store.sleepSessions(
            deviceId: Repository.whoopSource, from: now - 2 * 86_400, to: now, limit: 10
        ), let session = sessions.max(by: { $0.endTs < $1.endTs })
        else { return nil }

        let tz = TimeZone.current.secondsFromGMT()
        guard let json = session.stagesJSON,
            let segments = try? JSONDecoder().decode([StageSegment].self, from: Data(json.utf8)),
            let verdict = AlarmWakeQuality.stageAtAlarm(
                segments: segments, sessionEndTs: session.endTs,
                alarmMinutesSinceMidnight: alarmMinutes, tzOffsetSeconds: tz
            )
        else { return nil }

        let clock = BedtimeRecommendation.formatClock(alarmMinutes)
        switch verdict {
        case .light:
            return "Le réveil (\(clock)) est tombé en sommeil léger — bon timing."
        case .deep, .rem:
            return "Le réveil (\(clock)) est tombé en sommeil \(verdict == .deep ? "profond" : "paradoxal") — pas le moment idéal."
        case .wake, .unknown:
            return nil
        }
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
