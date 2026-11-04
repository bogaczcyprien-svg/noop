import Foundation
import Combine
import WhoopStore
import WhoopProtocol
#if os(iOS)
import UIKit
#endif

/// Pulls the user's Garmin data from their own collection server into the on-device store, under the
/// existing `garmin-import` source, so NOOP's own recovery / strain / sleep math and every screen run on
/// it exactly as they do for the Garmin export importer. Raw values only: the server's and Garmin's own
/// scores go to `ref_*` metric keys, never into NOOP's Charge/Effort/Rest.
///
/// First connect backfills the whole history the server holds; later syncs re-pull the last few days
/// (Garmin revises recent days) plus everything since the last sync. Foreground syncs are throttled.
@MainActor
final class GarminServerSync: ObservableObject {
    static let shared = GarminServerSync()

    static let deviceId = "garmin-import"
    private static let historyStart = "2026-08-15"
    private static let lastDayKey = "garminServer.lastSyncedDay"
    private static let lastRunKey = "garminServer.lastRunAt"
    private static let minInterval: TimeInterval = 15 * 60
    private static let overlapDays = 3

    @Published private(set) var busy = false
    @Published private(set) var statusText: String?
    @Published private(set) var failed = false
    @Published private(set) var isConnected = GarminServerTokenStore.load() != nil
    @Published private(set) var lastRunAt: Date? = {
        let t = UserDefaults.standard.double(forKey: lastRunKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }()

    var accountEmail: String? { GarminServerTokenStore.email }

    // MARK: - Actions

    func connect(email: String, password: String, repo: Repository) {
        guard !busy else { return }
        setBusy(true); failed = false
        statusText = String(localized: "Connecting to your server…")
        Task {
            do {
                let base = try await GarminServerClient.resolveBase()
                let token = try await GarminServerClient(base: base, token: nil)
                    .login(email: email.trimmingCharacters(in: .whitespaces), password: password)
                GarminServerTokenStore.save(token: token, email: email)
                UserDefaults.standard.removeObject(forKey: Self.lastDayKey)   // fresh account → full backfill
                isConnected = true
                await run(repo: repo, client: GarminServerClient(base: base, token: token))
            } catch {
                report(error)
            }
            setBusy(false)
        }
    }

    func syncNow(repo: Repository) {
        guard !busy, let token = GarminServerTokenStore.load() else { return }
        setBusy(true); failed = false
        Task {
            do {
                let client = GarminServerClient(base: try await GarminServerClient.resolveBase(), token: token)
                await client.requestServerSync()
                await run(repo: repo, client: client)
            } catch { report(error) }
            setBusy(false)
        }
    }

    /// Called when the app comes to the foreground: a quiet sync at most every 15 minutes.
    func syncIfDue(repo: Repository) {
        guard isConnected, !busy else { return }
        if let last = lastRunAt, Date().timeIntervalSince(last) < Self.minInterval { return }
        syncNow(repo: repo)
    }

    func disconnect(repo: Repository) {
        GarminServerTokenStore.clear()
        UserDefaults.standard.removeObject(forKey: Self.lastDayKey)
        UserDefaults.standard.removeObject(forKey: Self.lastRunKey)
        isConnected = false; lastRunAt = nil; failed = false
        statusText = String(localized: "Disconnected. Data already saved stays on this iPhone.")
    }

    // MARK: - Sync

    private func run(repo: Repository, client: GarminServerClient) async {
        guard let store = await repo.storeHandle() else { report(nil, String(localized: "Couldn't open the local store.")); return }
        let today = Self.dayFmt.string(from: Date())
        let from: String = {
            guard let last = UserDefaults.standard.string(forKey: Self.lastDayKey),
                  let d = Self.dayFmt.date(from: last) else { return Self.historyStart }
            let back = Calendar(identifier: .gregorian).date(byAdding: .day, value: -Self.overlapDays, to: d) ?? d
            return max(Self.historyStart, Self.dayFmt.string(from: back))
        }()
        let days = Self.days(from: from, to: today)

        do {
            // Register once (first backfill): re-adding would reset a status the user changed in Devices.
            if from == Self.historyStart { try registerSource(store) }
            var totals = (days: 0, sleeps: 0, hr: 0, workouts: 0)
            for (i, day) in days.enumerated() {
                statusText = String(localized: "Syncing \(day) (\(i + 1)/\(days.count))…")
                let r = try await syncDay(day, client: client, store: store)
                totals.days += r.day ? 1 : 0; totals.sleeps += r.sleep ? 1 : 0; totals.hr += r.hr
                // Checkpoint after every day so an interruption never re-pulls finished days.
                UserDefaults.standard.set(day, forKey: Self.lastDayKey)
            }
            statusText = String(localized: "Syncing workouts…")
            totals.workouts = try await syncActivities(since: from, client: client, store: store)

            await repo.refresh()
            let now = Date()
            lastRunAt = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastRunKey)
            failed = false
            statusText = String(localized: "Up to date · \(totals.days) days · \(totals.sleeps) nights · \(totals.workouts) workouts · \(totals.hr) heart-rate points")
        } catch {
            await repo.refresh()   // show whatever landed before the failure
            report(error)
        }
    }

    private func registerSource(_ store: WhoopStore) throws {
        let now = Int(Date().timeIntervalSince1970)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(
            id: Self.deviceId, brand: "Garmin", model: "CIRQA (server)",
            sourceKind: .cloudImport, capabilities: [.hr, .hrv, .spo2, .steps, .sleep],
            status: .paired, addedAt: now, lastSeenAt: now))
    }

    private func syncDay(_ day: String, client: GarminServerClient,
                         store: WhoopStore) async throws -> (day: Bool, sleep: Bool, hr: Int) {
        let t = try await client.get("today", ["date": day]) as? [String: Any] ?? [:]
        let sleep = (try? await client.get("sleep-detail", ["date": day])) as? [String: Any] ?? [:]
        let nightHR = Self.points((try? await client.get("night-heart-rate", ["date": day])) as? [String: Any])
        let dayHR = Self.points((try? await client.get("heart-rate-intraday", ["date": day])) as? [String: Any])

        let deep = Self.num(sleep["deep_minutes"]), light = Self.num(sleep["light_minutes"])
        let rem = Self.num(sleep["rem_minutes"])
        let total = Self.num(t["sleep_duration_minutes"])
            ?? ([deep, light, rem].allSatisfy { $0 != nil } ? deep! + light! + rem! : nil)
        let rhr = Self.num(t["resting_heart_rate"]).map { Int($0.rounded()) }
        let hrv = Self.num(t["avg_overnight_hrv"])
        let eff = Self.num(t["sleep_efficiency"])

        var wroteDay = false
        let hasAnything = [total, Self.num(t["steps"]), Self.num(t["resting_heart_rate"]), hrv].contains { $0 != nil }
        if hasAnything {
            let metric = DailyMetric(
                day: day, totalSleepMin: total, efficiency: eff,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Self.num(sleep["awakenings_count"]).map { Int($0) },
                restingHr: rhr, avgHrv: hrv,
                recovery: nil, strain: nil,          // NEVER the server's or Garmin's own scores
                exerciseCount: nil,
                spo2Pct: Self.num(t["spo2"]), skinTempDevC: nil,
                respRateBpm: Self.num(t["respiration_rate"]),
                steps: Self.num(t["steps"]).map { Int($0) }, activeKcalEst: nil)
            _ = try await store.upsertDailyMetrics([metric], deviceId: Self.deviceId)
            wroteDay = true
        }

        // Night window from the in-sleep HR points (the API has no explicit bed/wake times and no
        // per-epoch hypnogram, so no stage JSON is synthesized).
        var wroteSleep = false
        if let first = nightHR.first?.ts, let last = nightHR.last?.ts, last - first >= 3_600 {
            let lowest = nightHR.map(\.bpm).min()
            _ = try await store.upsertSleepSessions([CachedSleepSession(
                startTs: first, endTs: last, efficiency: eff,
                restingHr: rhr ?? lowest, avgHrv: hrv, stagesJSON: nil)], deviceId: Self.deviceId)
            wroteSleep = true
        }

        // Heart-rate samples (≈2 min apart) feed NOOP's strain / daytime HR / sleep HR math.
        var seen = Set<Int>()
        let hr = (dayHR + nightHR).filter { seen.insert($0.ts).inserted }.map { HRSample(ts: $0.ts, bpm: $0.bpm) }
        var hrCount = 0
        if !hr.isEmpty { hrCount = try await store.insert(Streams(hr: hr), deviceId: Self.deviceId).hr }

        // Browseable series (Metric Explorer / correlations), with the brand scores as reference only.
        var points: [MetricPoint] = []
        func add(_ key: String, _ v: Double?) { if let v { points.append(MetricPoint(day: day, key: key, value: v)) } }
        add("steps", Self.num(t["steps"]))
        add("total_kcal", Self.num(t["calories"]))
        add("rhr", Self.num(t["resting_heart_rate"]))
        add("hrv", hrv)
        add("spo2", Self.num(t["spo2"]))
        add("vo2max", Self.num(t["vo2max_cycling"]))
        add("sleep_total_min", total)
        add("sleep_deep_min", deep)
        add("sleep_light_min", light)
        add("sleep_rem_min", rem)
        add("ref_sleep_score", Self.num(t["sleep_score"]))
        if let stress = (try? await client.get("stress-today", ["date": day])) as? [String: Any] {
            let vals = Self.points(stress).map { Double($0.bpm) }
            if !vals.isEmpty { add("stress", vals.reduce(0, +) / Double(vals.count)) }
        }
        if !points.isEmpty { _ = try await store.upsertMetricSeries(points, deviceId: Self.deviceId) }

        return (wroteDay, wroteSleep, hrCount)
    }

    private func syncActivities(since: String, client: GarminServerClient, store: WhoopStore) async throws -> Int {
        let floor = Self.dayFmt.date(from: since)?.timeIntervalSince1970 ?? 0
        var rows: [WorkoutRow] = []
        var offset = 0
        pages: while offset < 2_000 {
            guard let page = try await client.get("activities", ["limit": "50", "offset": String(offset)]) as? [[String: Any]],
                  !page.isEmpty else { break }
            for a in page {
                guard let startStr = a["start_time"] as? String,
                      let start = Self.iso.date(from: startStr) ?? Self.isoFrac.date(from: startStr) else { continue }
                if start.timeIntervalSince1970 < floor { break pages }
                let dur = Self.num(a["duration_seconds"]) ?? 0
                let startTs = Int(start.timeIntervalSince1970)
                rows.append(WorkoutRow(
                    startTs: startTs, endTs: startTs + Int(dur.rounded()),
                    sport: Self.sport(a["activity_type"] as? String), source: "garmin",
                    durationS: dur, energyKcal: Self.num(a["calories"]),
                    avgHr: Self.num(a["avg_hr"]).map { Int($0.rounded()) },
                    maxHr: Self.num(a["max_hr"]).map { Int($0.rounded()) },
                    strain: nil, distanceM: Self.num(a["distance_meters"]), zonesJSON: nil,
                    notes: a["activity_name"] as? String, steps: nil))
            }
            offset += page.count
        }
        return rows.isEmpty ? 0 : try await store.upsertWorkouts(rows, deviceId: Self.deviceId)
    }

    // MARK: - Helpers

    private func report(_ error: Error?, _ message: String? = nil) {
        failed = true
        if case GarminServerClient.Failure.unauthorized? = error as? GarminServerClient.Failure {
            GarminServerTokenStore.clear(); isConnected = false
        }
        statusText = message ?? (error as? LocalizedError)?.errorDescription ?? error?.localizedDescription
    }

    /// Busy also keeps the screen awake on iOS so a long first backfill isn't frozen by auto-lock.
    private func setBusy(_ b: Bool) {
        busy = b
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = b
        #endif
    }

    /// Garmin `activity_type` keys → NOOP's sport names (WorkoutCatalog); unknown types read "Other".
    static func sport(_ type: String?) -> String {
        switch type?.lowercased() ?? "" {
        case "cycling", "road_biking", "mountain_biking", "gravel_cycling", "cyclocross", "e_bike_fitness", "bmx":
            return "Cycling"
        case "indoor_cycling", "virtual_ride", "spinning": return "Indoor cycle"
        case "running", "trail_running", "street_running", "track_running", "ultra_run": return "Running"
        case "treadmill_running", "indoor_running": return "Treadmill run"
        case "walking", "casual_walking", "speed_walking": return "Walking"
        case "hiking": return "Hiking"
        case "lap_swimming": return "Pool swim"
        case "open_water_swimming": return "Open-water swim"
        case "rowing": return "Rowing"
        case "indoor_rowing": return "Row machine"
        case "elliptical": return "Elliptical"
        case "strength_training": return "Strength"
        case "hiit": return "HIIT"
        case "yoga": return "Yoga"
        case "pilates": return "Pilates"
        case "tennis": return "Tennis"
        case "boxing": return "Boxing"
        default: return WorkoutCatalog.defaultSportName
        }
    }

    static func num(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d.isFinite ? d : nil
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// `{"points":[{"timestamp": <epoch ms UTC>, "value": n}]}` → (unix seconds, value), time-ordered.
    static func points(_ obj: [String: Any]?) -> [(ts: Int, bpm: Int)] {
        let raw = obj?["points"] as? [[String: Any]] ?? []
        return raw.compactMap { p -> (ts: Int, bpm: Int)? in
            guard let ms = num(p["timestamp"]), let v = num(p["value"]), v > 0 else { return nil }
            return (Int(ms / 1000), Int(v.rounded()))
        }.sorted { $0.ts < $1.ts }
    }

    static func days(from: String, to: String) -> [String] {
        guard var d = dayFmt.date(from: from), let end = dayFmt.date(from: to) else { return [to] }
        var out: [String] = []
        let cal = Calendar(identifier: .gregorian)
        while d <= end, out.count < 1_000 {
            out.append(dayFmt.string(from: d))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? end.addingTimeInterval(1)
        }
        return out
    }

    /// Server days are calendar days in the user's zone (the server collects on Europe/Paris), which is
    /// also how `DailyMetric.day` is keyed locally.
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
    private static let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
}
