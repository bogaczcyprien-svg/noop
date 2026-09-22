#if os(iOS)
import Foundation
import GRDB
import WhoopStore

/// Imports activities from intervals.icu into `WhoopStore.workout` (its own `intervals-icu` device
/// partition, mirroring the `apple-health` import convention) AND backfills approximate `hrSample`
/// rows under the strap's OWN device id (`Repository.whoopSource`) so NOOP's existing day-Strain
/// integration — which deliberately reads one device's hr stream, never a mix — picks up rides where
/// the strap wasn't worn. This is a deliberate exception to NOOP's source-separation convention,
/// made knowingly: see the More > Data > intervals.icu screen for the tradeoff it documents.
///
/// intervals.icu's base activities endpoint only returns one avgHr per ride, not a per-second
/// stream, so the backfilled samples are a flat repeat of avgHr every 60s across the ride — an
/// approximation, not a measured trace. `INSERT OR IGNORE` never overwrites a real strap sample.
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
        let count = try await store.upsertWorkouts(rows, deviceId: deviceId)
        try await backfillApproximateHR(activities: activities, store: store)
        return count
    }

    /// Flat approximate HR at `average_heartrate`, one sample per minute across the ride, written
    /// under the strap's own device id so the day-window Strain integration sees it.
    private static func backfillApproximateHR(activities: [IntervalsICUActivity], store: WhoopStore) async throws {
        var rows: [(ts: Int, bpm: Int)] = []
        for a in activities {
            guard let startLocal = a.start_date_local, let avgHr = a.average_heartrate else { continue }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.calendar = Calendar(identifier: .gregorian)
            guard let start = formatter.date(from: startLocal) else { continue }
            let startTs = Int(start.timeIntervalSince1970)
            let duration = a.moving_time ?? a.elapsed_time ?? 0
            guard duration > 0 else { continue }
            let bpm = Int(avgHr.rounded())
            var t = startTs
            while t <= startTs + duration {
                rows.append((ts: t, bpm: bpm))
                t += 60
            }
        }
        guard !rows.isEmpty else { return }
        let writer = store.registryWriter
        try await writer.write { db in
            for row in rows {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)",
                    arguments: [Repository.whoopSource, row.ts, row.bpm]
                )
            }
        }
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
