#if os(iOS)
import Foundation
import WhoopStore

/// Pushes last night's already-computed sleep/recovery summary TO intervals.icu's wellness entry —
/// the reverse direction of `IntervalsICUImporter`, which pulls activities FROM it. Opt-in, default
/// off (`IntervalsICUSettings.pushEnabled`); nothing is ever read back for this direction, matching
/// NOOP's one-way-export convention (see the self-hosted push client for the same shape).
public enum IntervalsICUWellnessPush {
    /// What happened, for the caller to surface — `pushLatestNight` used to return silently (and
    /// identically) whether it was off, misconfigured, or genuinely had nothing to send, which left no
    /// way to tell "never ran" from "ran and found nothing" from a real failure.
    public enum Outcome: Equatable {
        case pushed(day: String)
        case disabled
        case noApiKey
        /// No day in the lookback window has `totalSleepMin` yet — e.g. last night hasn't finished
        /// scoring, or the strap hasn't synced recently enough for a day to carry sleep data.
        case nothingToPush
    }

    /// `@MainActor` so it can read `ProfileStore` (weight) directly — the caller (`IntervalsICURunner`)
    /// is already MainActor, so this costs no extra hop.
    @MainActor
    public static func pushLatestNight(store: WhoopStore) async throws -> Outcome {
        guard await IntervalsICUSettings.shared.pushEnabled else { return .disabled }
        guard let apiKey = await IntervalsICUSettings.shared.apiKey(), !apiKey.isEmpty else {
            return .noApiKey
        }
        let athleteId = await IntervalsICUSettings.shared.athleteId
        let client = IntervalsICUClient(athleteId: athleteId, apiKey: apiKey)
        let fields = IntervalsICUSettings.shared.pushFields

        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        guard let from = cal.date(byAdding: .day, value: -2, to: today) else { return .nothingToPush }
        let fromStr = PushDayFormat.formatter.string(from: from)
        let toStr = PushDayFormat.formatter.string(from: today)

        // UNION the active strap's id with the canonical "my-whoop" id, active-first — the same
        // resolution `Repository.importedReadIds`/`unionDailyMetrics` give every other reader of
        // DailyMetric (Today's own Recovery/Sleep display among them). A single hardcoded
        // `Repository.whoopSource` read here found NOTHING for an install whose active strap carries
        // a different registry id (e.g. a WHOOP 5.0/MG paired after the canonical id was already in
        // use, or re-added), even though the SAME nights show real sleep data on Today — this runner
        // has no `Repository` instance (it opens its own standalone `WhoopStore`), so it resolves the
        // active id the same way `SkinTempBackfillWalker` does, straight off the registry.
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let activeId = (try? registry.activeDeviceId()) ?? Repository.whoopSource
        let readIds = activeId == Repository.whoopSource ? [activeId] : [activeId, Repository.whoopSource]

        var byDay: [String: DailyMetric] = [:]
        for id in readIds {
            for m in (try? await store.dailyMetrics(deviceId: id, from: fromStr, to: toStr)) ?? [] {
                byDay[m.day] = byDay[m.day].map { Repository.coalesceDay($0, m) } ?? m
            }
        }
        guard let latest = byDay.values.sorted(by: { $0.day < $1.day })
            .last(where: { $0.totalSleepMin != nil }) else { return .nothingToPush }

        let sleepSecs = fields.contains(.sleep) ? latest.totalSleepMin.map { Int(($0 * 60).rounded()) } : nil
        let sleepScore = fields.contains(.sleep) ? latest.efficiency.map { Int(($0 * 100).rounded()) } : nil
        try await client.putWellness(
            date: latest.day,
            hrv: fields.contains(.hrv) ? latest.avgHrv : nil,
            restingHR: fields.contains(.restingHR) ? latest.restingHr : nil,
            sleepSecs: sleepSecs,
            sleepScore: sleepScore,
            weightKg: fields.contains(.weight) ? ProfileStore().weightKg : nil,
            steps: fields.contains(.steps) ? latest.steps : nil
        )
        return .pushed(day: latest.day)
    }
}
#endif
