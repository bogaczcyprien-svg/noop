#if os(iOS)
import Foundation
import WhoopStore

/// Pushes last night's already-computed sleep/recovery summary TO intervals.icu's wellness entry —
/// the reverse direction of `IntervalsICUImporter`, which pulls activities FROM it. Opt-in, default
/// off (`IntervalsICUSettings.pushEnabled`); nothing is ever read back for this direction, matching
/// NOOP's one-way-export convention (see the self-hosted push client for the same shape).
public enum IntervalsICUWellnessPush {
    public static func pushLatestNight(store: WhoopStore) async throws {
        guard await IntervalsICUSettings.shared.pushEnabled else { return }
        guard let apiKey = await IntervalsICUSettings.shared.apiKey(), !apiKey.isEmpty else {
            throw IntervalsICUError.http(401)
        }
        let athleteId = await IntervalsICUSettings.shared.athleteId
        let client = IntervalsICUClient(athleteId: athleteId, apiKey: apiKey)

        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        guard let from = cal.date(byAdding: .day, value: -2, to: today) else { return }
        let days = try await store.dailyMetrics(
            deviceId: Repository.whoopSource,
            from: PushDayFormat.formatter.string(from: from),
            to: PushDayFormat.formatter.string(from: today)
        )
        guard let latest = days.sorted(by: { $0.day < $1.day })
            .last(where: { $0.totalSleepMin != nil }) else { return }

        let sleepSecs = latest.totalSleepMin.map { Int(($0 * 60).rounded()) }
        let sleepScore = latest.efficiency.map { Int(($0 * 100).rounded()) }
        try await client.putWellness(
            date: latest.day,
            hrv: latest.avgHrv,
            restingHR: latest.restingHr,
            sleepSecs: sleepSecs,
            sleepScore: sleepScore
        )
    }
}
#endif
