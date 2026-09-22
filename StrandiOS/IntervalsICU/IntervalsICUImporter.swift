#if os(iOS)
import Foundation
import WhoopStore

/// Imports activities from intervals.icu into `WhoopStore.workout` under the `intervals-icu`
/// device partition (mirrors the `apple-health` partition already used for imported Apple Health
/// data — see docs/ARCHITECTURE.md §7). Read-only against intervals.icu; NOOP never writes back.
public struct IntervalsICUImporter {
    public static let deviceId = "intervals-icu"

    public static func importRecent(days: Int, store: WhoopStore) async throws -> Int {
        guard let apiKey = await IntervalsICUSettings.shared.apiKey(), !apiKey.isEmpty else {
            throw IntervalsICUError.http(401)
        }
        let athleteId = await IntervalsICUSettings.shared.athleteId
        let client = IntervalsICUClient(athleteId: athleteId, apiKey: apiKey)

        let cal = Calendar(identifier: .gregorian)
        let today = Date()
        let from = cal.date(byAdding: .day, value: -days, to: today) ?? today
        let activities = try await client.activities(
            oldest: PushDayFormat.formatter.string(from: from),
            newest: PushDayFormat.formatter.string(from: today)
        )

        let rows = activities.compactMap(toWorkoutRow)
        return try await store.upsertWorkouts(rows, deviceId: deviceId)
    }

    private static func toWorkoutRow(_ a: IntervalsICUActivity) -> WorkoutRow? {
        guard let startLocal = a.start_date_local else { return nil }
        // intervals.icu returns e.g. "2026-09-20T07:15:03" — no offset; treat as UTC seconds since
        // this row only needs a stable ordering key, not clock-accurate provenance.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        guard let start = formatter.date(from: startLocal) else { return nil }
        let startTs = Int(start.timeIntervalSince1970)
        let duration = a.moving_time ?? a.elapsed_time ?? 0
        let endTs = startTs + duration

        return WorkoutRow(
            startTs: startTs,
            endTs: endTs,
            sport: a.type ?? "Workout",
            source: "intervals.icu",
            durationS: duration > 0 ? Double(duration) : nil,
            energyKcal: a.calories,
            avgHr: a.average_heartrate.map { Int($0.rounded()) },
            maxHr: a.max_heartrate.map { Int($0.rounded()) },
            strain: nil,   // NOOP computes its own Strain from HR data it decodes itself; never borrowed.
            distanceM: a.distance,
            zonesJSON: nil,
            notes: a.name,
            steps: nil
        )
    }
}
#endif
