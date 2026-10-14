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
        await deduplicateTimezoneArtifacts(store: store)
        return count
    }

    /// One-time cleanup for a specific, now-fixed historical bug: before `localDateFormatter` existed,
    /// every imported ride's `startTs`/`endTs` came from mislabeling `start_date_local` as UTC. For any
    /// non-UTC user, a later sync running the FIXED parser re-imported the same ride under its correct
    /// (different) time — `upsertWorkouts`' natural key is (deviceId, startTs, sport), so the new,
    /// correct row did not overwrite the old, wrong one, it sat beside it (a confirmed, user-reported
    /// case: the same ride appeared twice, 2h apart, identical stats).
    ///
    /// Finds exact-duplicate PAIRS in the "intervals-icu" partition only (the device id no other writer
    /// touches): same (sport, durationS, avgHr, maxHr, distanceM, energyKcal, notes) but a different
    /// startTs, where the gap between the two timestamps is EXACTLY `TimeZone.current`'s UTC offset at
    /// the correct one's instant — the precise signature of "the same wall-clock string parsed once as
    /// UTC and once as local", not a loose nearby-time heuristic. Deletes only the UTC-mislabeled one.
    ///
    /// Does NOT touch the backfilled `hrSample` rows the old, wrong import window wrote under the
    /// strap's own device id (`Repository.whoopSource`) — those sit in the SAME table a real strap
    /// sample would, with no provenance tag distinguishing them, so removing them risks deleting a
    /// genuine reading the strap recorded at that same old (now-stale) clock time. That gap is real and
    /// unresolved; this only fixes the visible, unambiguous workout-list duplicate.
    static func deduplicateTimezoneArtifacts(store: WhoopStore) async {
        let farFuture = Int(Date().timeIntervalSince1970) + 86_400
        guard let rows = try? await store.workouts(deviceId: deviceId, from: 0, to: farFuture, limit: 5000),
              rows.count >= 2 else { return }

        var toDelete: [(sport: String, startTs: Int)] = []
        var consumed = Set<Int>()
        for i in rows.indices {
            guard !consumed.contains(i) else { continue }
            for j in (i + 1)..<rows.count {
                guard !consumed.contains(j) else { continue }
                let a = rows[i], b = rows[j]
                guard a.sport == b.sport, a.startTs != b.startTs, a.durationS == b.durationS,
                      a.avgHr == b.avgHr, a.maxHr == b.maxHr, a.distanceM == b.distanceM,
                      a.energyKcal == b.energyKcal, a.notes == b.notes
                else { continue }
                if isUTCMislabeledPair(oldCandidateTs: a.startTs, newCandidateTs: b.startTs) {
                    toDelete.append((a.sport, a.startTs))
                } else if isUTCMislabeledPair(oldCandidateTs: b.startTs, newCandidateTs: a.startTs) {
                    toDelete.append((b.sport, b.startTs))
                } else {
                    continue
                }
                consumed.insert(i); consumed.insert(j)
                break
            }
        }
        for d in toDelete {
            _ = try? await store.deleteWorkouts(deviceId: deviceId, sport: d.sport, from: d.startTs, to: d.startTs)
        }
    }

    /// True when `oldCandidateTs` is exactly what you get by parsing the SAME wall-clock string that
    /// produced `newCandidateTs` as UTC instead of as `TimeZone.current` — i.e. `oldTs - newTs` equals
    /// the local UTC offset AT `newCandidateTs`'s own instant (evaluated there, not "now", so a DST
    /// transition between the ride and today can't throw the comparison off by an hour).
    private static func isUTCMislabeledPair(oldCandidateTs: Int, newCandidateTs: Int) -> Bool {
        let offset = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(newCandidateTs)))
        return oldCandidateTs - newCandidateTs == offset
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

    /// intervals.icu returns `start_date_local` as a wall-clock string with no offset (e.g.
    /// "2026-09-20T07:15:03" — 7:15am wherever the ride happened), not UTC. `IntervalsICUPlannedView`
    /// already parses this same field with `TimeZone.current` for display; this formatter matches that
    /// convention rather than mislabeling the string UTC, which shifted every backfilled HR sample (and
    /// the calorie/step exclusion windows built from `WorkoutRow.startTs/endTs`) by the device's UTC
    /// offset for any non-UTC user.
    private static let localDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()

    private static func startTs(_ a: IntervalsICUActivity) -> Int? {
        guard let startLocal = a.start_date_local,
              let start = localDateFormatter.date(from: startLocal) else { return nil }
        return Int(start.timeIntervalSince1970)
    }

    private static func toWorkoutRow(_ a: IntervalsICUActivity) -> WorkoutRow? {
        guard let startLocal = a.start_date_local,
              let start = localDateFormatter.date(from: startLocal) else { return nil }
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
