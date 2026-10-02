#if os(iOS)
import Foundation
import GRDB
import WhoopStore

/// Imports activities from intervals.icu into `WhoopStore.workout` (its own `intervals-icu` device
/// partition, mirroring the `apple-health` import convention) AND backfills `hrSample` rows under the
/// strap's OWN device id (`Repository.whoopSource`) so NOOP's existing day-Strain integration — which
/// deliberately reads one device's hr stream, never a mix — picks up rides where the strap wasn't
/// worn. This is a deliberate exception to NOOP's source-separation convention, made knowingly: see
/// the More > Data > intervals.icu screen for the tradeoff it documents.
///
/// Prefers intervals.icu's real per-sample streams endpoint (actual recorded HR at its actual
/// offsets) over the base `activities` call's single ride-average; falls back to a flat repeat of
/// that average only when the streams fetch fails or carries no heart-rate data (e.g. a ride recorded
/// without a chest strap/arm band). `INSERT OR IGNORE` never overwrites a real strap sample either way.
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
        await backfillHR(activities: activities, client: client, store: store)
        return count
    }

    private static func backfillHR(activities: [IntervalsICUActivity], client: IntervalsICUClient,
                                   store: WhoopStore) async {
        for a in activities {
            guard let startTs = startTs(a) else { continue }
            let duration = a.moving_time ?? a.elapsed_time ?? 0
            guard duration > 0 else { continue }

            if let real = try? await client.streams(activityId: a.id, types: ["time", "heartrate"]),
               let rows = realHRRows(streams: real, activityStartTs: startTs), !rows.isEmpty {
                await insert(rows, store: store)
            } else if let avgHr = a.average_heartrate {
                await insert(flatHRRows(startTs: startTs, duration: duration, bpm: Int(avgHr.rounded())),
                           store: store)
            }
        }
    }

    /// Real recorded HR at its actual offsets, or nil when the streams response doesn't carry both a
    /// usable "time" and "heartrate" stream (missing entirely, empty, or a device that recorded no
    /// HR for this ride) — the caller falls back to the flat approximation in that case.
    static func realHRRows(streams: [IntervalsICUStream], activityStartTs: Int) -> [(ts: Int, bpm: Int)]? {
        guard let time = streams.first(where: { $0.type == "time" })?.data,
              let hr = streams.first(where: { $0.type == "heartrate" })?.data,
              !time.isEmpty, !hr.isEmpty
        else { return nil }
        var rows: [(ts: Int, bpm: Int)] = []
        rows.reserveCapacity(min(time.count, hr.count))
        for i in 0..<min(time.count, hr.count) {
            guard let offset = time[i], let bpm = hr[i], bpm > 0 else { continue }
            rows.append((ts: activityStartTs + Int(offset.rounded()), bpm: Int(bpm.rounded())))
        }
        return rows
    }

    /// Flat approximate HR at `bpm`, one sample per minute across the ride — the pre-streams fallback,
    /// kept for rides the streams endpoint can't supply real HR for.
    private static func flatHRRows(startTs: Int, duration: Int, bpm: Int) -> [(ts: Int, bpm: Int)] {
        var rows: [(ts: Int, bpm: Int)] = []
        var t = startTs
        while t <= startTs + duration {
            rows.append((ts: t, bpm: bpm))
            t += 60
        }
        return rows
    }

    private static func insert(_ rows: [(ts: Int, bpm: Int)], store: WhoopStore) async {
        guard !rows.isEmpty else { return }
        try? await store.registryWriter.write { db in
            for row in rows {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)",
                    arguments: [Repository.whoopSource, row.ts, row.bpm]
                )
            }
        }
    }

    private static func startTs(_ a: IntervalsICUActivity) -> Int? {
        guard let startLocal = a.start_date_local else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        guard let start = formatter.date(from: startLocal) else { return nil }
        return Int(start.timeIntervalSince1970)
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
