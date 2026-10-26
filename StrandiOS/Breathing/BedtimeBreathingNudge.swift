#if os(iOS)
import Foundation
import UserNotifications
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// Evening breathing nudge (fork addition): between 21:00 and 23:00, when the WHOOP's latest data shows
/// the wearer lying still and not yet asleep (`BedtimeBreathingGate`), post one local
/// notification suggesting a coherence session. At most once per evening, and not after a breathing
/// session already done that evening.
///
/// It runs after each strap offload (the same hook as the sleep recap), so it fires within one sync of
/// the wearer settling, not to the minute. On by default at the fork owner's request; the Breathing tab
/// carries the switch. Local only; nothing leaves the phone.
@MainActor
final class BedtimeBreathingNudge {
    static let shared = BedtimeBreathingNudge()

    static let categoryId = "noop.breathing.bedtime"
    private let enabledKey = "noop.breathing.bedtimeNudge"
    private let lastPostedKey = "noop.breathing.bedtimeNudge.lastDay"
    private let lastSessionKey = "noop.breathing.lastSessionTs"

    private var cachedStore: WhoopStore?

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) == nil || UserDefaults.standard.bool(forKey: enabledKey)
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on { requestPermissionIfNeeded() }
    }

    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    /// A breathing session just ended: no nudge later this evening.
    func noteSessionDone(at date: Date = Date()) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: lastSessionKey)
    }

    func checkIfDue(now: Date = Date()) async {
        guard isEnabled else { return }
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        guard BedtimeBreathingGate.windowMinutes.contains(minute) else { return }
        let dayKey = PushDayFormat.formatter.string(from: now)
        guard UserDefaults.standard.string(forKey: lastPostedKey) != dayKey else { return }
        let lastSession = UserDefaults.standard.double(forKey: lastSessionKey)
        if lastSession > 0, now.timeIntervalSince1970 - lastSession < 3 * 3600 { return }

        guard let store = await store() else { return }
        let nowTs = Int(now.timeIntervalSince1970)
        let from = nowTs - BedtimeBreathingGate.lookbackSeconds
        // Raw streams sit under the strap's own id and the canonical one (`Repository.rawWhoopSourceIds`);
        // read every paired WHOOP plus the canonical id, as the Repository does.
        let paired = ((try? DeviceRegistryStore(dbQueue: store.registryWriter).all()) ?? [])
            .filter { $0.brand.caseInsensitiveCompare("WHOOP") == .orderedSame }.map(\.id)
        var hr: [HRSample] = []
        var grav: [GravitySample] = []
        var band: [(ts: Int, state: Int)] = []
        for id in Set(paired + [Repository.whoopSource]) {
            hr += (try? await store.hrSamples(deviceId: id, from: from, to: nowTs, limit: 5_000)) ?? []
            grav += (try? await store.gravitySamples(deviceId: id, from: from, to: nowTs, limit: 20_000)) ?? []
            band += ((try? await store.sleepStateSamples(deviceId: id, from: from, to: nowTs, limit: 5_000)) ?? [])
                .map { (ts: $0.ts, state: $0.state) }
        }
        let resting = await restingHR(store: store, now: now)
        guard BedtimeBreathingGate.evaluate(now: nowTs, localMinuteOfDay: minute, hr: hr, grav: grav,
                                            restingHR: resting, bandStates: band) == .nudge else { return }

        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Time to breathe")
        content.body = String(localized: "You look settled in bed. Five minutes of cardiac coherence helps you fall asleep.")
        content.sound = .default
        content.categoryIdentifier = Self.categoryId
        let request = UNNotificationRequest(identifier: "\(Self.categoryId).\(dayKey)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        UserDefaults.standard.set(dayKey, forKey: lastPostedKey)
    }

    private func restingHR(store: WhoopStore, now: Date) async -> Double? {
        guard let from = Calendar.current.date(byAdding: .day, value: -7, to: now),
              let days = try? await store.dailyMetrics(deviceId: Repository.whoopSource,
                                                       from: PushDayFormat.formatter.string(from: from),
                                                       to: PushDayFormat.formatter.string(from: now))
        else { return nil }
        let values = days.compactMap(\.restingHr).map(Double.init)
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
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
