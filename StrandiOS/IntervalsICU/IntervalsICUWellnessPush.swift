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
        let days = try await store.dailyMetrics(
            deviceId: Repository.whoopSource,
            from: PushDayFormat.formatter.string(from: from),
            to: PushDayFormat.formatter.string(from: today)
        )
        guard let latest = days.sorted(by: { $0.day < $1.day })
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
