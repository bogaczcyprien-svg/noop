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

        // UNION all four id namespaces Today's own dashboard reads, active-strap-first within each
        // half: the active strap's IMPORTED id, the canonical "my-whoop" IMPORTED id, the active
        // strap's COMPUTED ("-noop") id, and the canonical "my-whoop-noop" COMPUTED id.
        //
        // A first fix here unioned only the two IMPORTED ids and still found nothing — because for a
        // live, BLE-only strap with no CSV/HealthKit import, `totalSleepMin` is written ONLY under the
        // COMPUTED ("-noop") id by `IntelligenceEngine.analyzeRecent`'s nightly scoring pass, never
        // under the plain imported id. `Repository.mergeDaily(imported:computed:)` is what blends BOTH
        // halves for Today's own Recovery/Sleep display (imported wins when present, computed fills
        // the rest) — this runner has no `Repository` instance (it opens its own standalone
        // `WhoopStore`), so it replicates that same four-id union directly, resolving the active id
        // off the registry the same way `SkinTempBackfillWalker` does. Imported ids listed first so
        // they win per `coalesceDay`, matching `mergeDaily`'s stated precedence.
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let activeId = (try? registry.activeDeviceId()) ?? Repository.whoopSource
        let canonicalId = Repository.whoopSource
        let importedIds = activeId == canonicalId ? [activeId] : [activeId, canonicalId]
        let computedIds = importedIds.map { $0 + "-noop" }
        let readIds = importedIds + computedIds

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
            readiness: fields.contains(.charge) ? latest.recovery : nil,
            sleepSecs: sleepSecs,
            sleepScore: sleepScore,
            weightKg: fields.contains(.weight) ? ProfileStore().weightKg : nil,
            steps: fields.contains(.steps) ? latest.steps : nil
        )
        return .pushed(day: latest.day)
    }
}
#endif
