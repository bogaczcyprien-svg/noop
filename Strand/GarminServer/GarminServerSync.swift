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

    nonisolated static let deviceId = "garmin-import"
    private static let historyStart = "2026-08-15"
    private static let lastDayKey = "garminServer.lastSyncedDay.v3"   // v3: re-pull all days once, efficiency was stored as a percentage
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

    /// The app's live state, set at launch, so the Today header shows this sync like a strap offload
    /// (pulsing sync dot while it runs, then "last synced" or the error).
    weak var live: LiveState?

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

    /// `askServer` also asks the server to pull Garmin right away (the "Sync now" button). Automatic syncs
    /// only read what the server already has, so they never add Garmin polling beyond its 15-minute cron.
    func syncNow(repo: Repository, askServer: Bool = true) {
        guard !busy, let token = GarminServerTokenStore.load() else { return }
        setBusy(true); failed = false
        Task {
            do {
                let client = GarminServerClient(base: try await GarminServerClient.resolveBase(), token: token)
                if askServer { await client.requestServerSync() }
                await run(repo: repo, client: client)
            } catch { report(error) }
            setBusy(false)
        }
    }

    /// Every app open reads the server (`force`); while the app stays open, a re-read every 15 minutes.
    func syncIfDue(repo: Repository, force: Bool = false) {
        guard isConnected, !busy else { return }
        if !force, let last = lastRunAt, Date().timeIntervalSince(last) < Self.minInterval { return }
        syncNow(repo: repo, askServer: false)
    }

    /// While the app stays in the foreground, re-check every minute so today's heart rate, steps and
    /// stress keep following the server's 15-minute pulls without reopening the app. iOS suspends the
    /// task in the background; the foreground hook restarts it.
    private var autoRefresh: Task<Void, Never>?
    func startAutoRefresh(repo: Repository) {
        autoRefresh?.cancel()
        autoRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.syncIfDue(repo: repo)
            }
        }
    }
    func stopAutoRefresh() { autoRefresh?.cancel(); autoRefresh = nil }

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
        live?.backfilling = true
        defer { live?.backfilling = false }

        do {
            // Register once (first backfill): re-adding would reset a status the user changed in Devices.
            if from == Self.historyStart { try registerSource(store) }
            var totals = (days: 0, sleeps: 0, hr: 0)
            // A long backfill fetches today and yesterday first, so the screens fill at once instead of
            // after every older day; the in-order pass below then skips them and keeps the checkpoint.
            let head = days.count > 4 ? Array(days.suffix(2)) : []
            for day in head {
                statusText = String(localized: "Syncing \(day) (\(totals.days + 1)/\(days.count))…")
                let r = try await syncDay(day, client: client, store: store, recent: true)
                totals.days += r.day ? 1 : 0; totals.sleeps += r.sleep ? 1 : 0; totals.hr += r.hr
            }
            if !head.isEmpty { await repo.refresh() }
            for (i, day) in days.enumerated() where !head.contains(day) {
                statusText = String(localized: "Syncing \(day) (\(i + 1)/\(days.count))…")
                let r = try await syncDay(day, client: client, store: store, recent: i >= days.count - 2)
                totals.days += r.day ? 1 : 0; totals.sleeps += r.sleep ? 1 : 0; totals.hr += r.hr
                // Checkpoint after every day so an interruption never re-pulls finished days.
                UserDefaults.standard.set(day, forKey: Self.lastDayKey)
            }
            if let last = head.last { UserDefaults.standard.set(last, forKey: Self.lastDayKey) }
            totals.hr += try await upgradeCoarseDays(client: client, store: store, skip: Set(days))

            let now = Date()
            // The Devices card's "last seen" reads the registry; a completed server sync is this source's contact.
            try? DeviceRegistryStore(dbQueue: store.registryWriter)
                .touchLastSeen(Self.deviceId, at: Int(now.timeIntervalSince1970))
            await repo.refresh()
            lastRunAt = now
            UserDefaults.standard.set(now.timeIntervalSince1970, forKey: Self.lastRunKey)
            live?.lastSyncedAt = now.timeIntervalSince1970
            live?.lastSyncError = nil
            failed = false
            statusText = String(localized: "Up to date · \(totals.days) days · \(totals.sleeps) nights · \(totals.hr) heart-rate points")
        } catch {
            await repo.refresh()   // show whatever landed before the failure
            report(error)
        }
    }

    /// The ~60 s series for `day`, or nil when the server couldn't serve it in time (not cached yet).
    /// A cached day with no wear returns an empty array, which is final, not a retry.
    private func fetchRawHR(_ day: String, client: GarminServerClient, timeout: TimeInterval) async -> [(ts: Int, bpm: Int)]? {
        guard let obj = (try? await client.get("heart-rate-raw", ["date": day], timeout: timeout)) as? [String: Any] else { return nil }
        return Self.points(obj)
    }

    private static let coarseKey = "garminServer.coarseHRDays"
    private func markCoarse(_ day: String, _ coarse: Bool) {
        var set = Set(UserDefaults.standard.stringArray(forKey: Self.coarseKey) ?? [])
        if coarse { set.insert(day) } else { set.remove(day) }
        UserDefaults.standard.set(Array(set).sorted(), forKey: Self.coarseKey)
    }

    /// Re-fetch up to `limit` days that only got the 2-min series, now that the server has likely cached
    /// their ~60 s series (it fills about one past day per 15 minutes). Newest first.
    private func upgradeCoarseDays(client: GarminServerClient, store: WhoopStore, skip: Set<String>,
                                   limit: Int = 30) async throws -> Int {
        let pending = (UserDefaults.standard.stringArray(forKey: Self.coarseKey) ?? [])
            .filter { !skip.contains($0) }.sorted(by: >).prefix(limit)
        var added = 0
        for day in pending {
            guard let pts = await fetchRawHR(day, client: client, timeout: 8) else { continue }
            if !pts.isEmpty {
                added += try await store.insert(Streams(hr: pts.map { HRSample(ts: $0.ts, bpm: $0.bpm) }),
                                                deviceId: Self.deviceId).hr
            }
            markCoarse(day, false)
        }
        return added
    }

    private func registerSource(_ store: WhoopStore) throws {
        let now = Int(Date().timeIntervalSince1970)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(
            id: Self.deviceId, brand: "Garmin", model: "CIRQA (server)",
            sourceKind: .cloudImport, capabilities: [.hr, .hrv, .spo2, .steps, .sleep],
            status: .paired, addedAt: now, lastSeenAt: now))
    }

    private func syncDay(_ day: String, client: GarminServerClient,
                         store: WhoopStore, recent: Bool) async throws -> (day: Bool, sleep: Bool, hr: Int) {
        // A day the server holds nothing for answers 404: that day is simply empty. Any other failure
        // (server unreachable, expired session) still stops the run so the checkpoint never skips a day.
        let t: [String: Any]
        do {
            t = try await client.get("today", ["date": day]) as? [String: Any] ?? [:]
        } catch GarminServerClient.Failure.http(404) {
            t = [:]
        }
        let sleep = (try? await client.get("sleep-detail", ["date": day])) as? [String: Any] ?? [:]
        let nightHR = Self.points((try? await client.get("night-heart-rate", ["date": day])) as? [String: Any])
        // Day heart rate: the server's ~60 s wellness-FIT series. It is cached server-side (instant); an
        // uncached day is decoded on demand (~20 s), which only the two most recent days wait for. Older
        // uncached days fall back to the 2-min summary and are upgraded on a later sync (see upgradeCoarseDays).
        if recent { statusText = String(localized: "Fetching detailed heart rate for \(day)…") }
        // A finished day whose detailed series is already stored is not fetched again: a re-pull of the
        // history (a checkpoint bump) then costs a few fast summary requests per day, not a wait on the
        // server's on-demand decode. Coarse days stay with `upgradeCoarseDays`.
        let dayStartTs = Self.dayFmt.date(from: day).map { Int($0.timeIntervalSince1970) } ?? 0
        let isCoarse = (UserDefaults.standard.stringArray(forKey: Self.coarseKey) ?? []).contains(day)
        let haveHR = !recent && !isCoarse && !((try? await store.hrSamples(
            deviceId: Self.deviceId, from: dayStartTs, to: dayStartTs + 86_399, limit: 1)) ?? []).isEmpty
        let raw = haveHR ? [] : await fetchRawHR(day, client: client, timeout: recent ? 90 : 8)
        var dayHR = raw ?? []
        // The two most recent days also take the 2-min series every pass: a still-running day's ~60 s file can
        // be cached server-side mid-day, and the 2-min series is what keeps today's curve growing until evening.
        if !haveHR && (dayHR.isEmpty || recent) {
            let rawTs = Set(dayHR.map(\.ts))
            dayHR += Self.points((try? await client.get("heart-rate-intraday", ["date": day])) as? [String: Any])
                .filter { !rawTs.contains($0.ts) && $0.ts > (dayHR.last?.ts ?? 0) }
        }
        markCoarse(day, raw == nil)

        let deep = Self.num(sleep["deep_minutes"]), light = Self.num(sleep["light_minutes"])
        let rem = Self.num(sleep["rem_minutes"])
        // 0 min means Garmin recorded no night, not a night of zero sleep.
        let total = (Self.num(t["sleep_duration_minutes"])
            ?? ([deep, light, rem].allSatisfy { $0 != nil } ? deep! + light! + rem! : nil)).flatMap { $0 > 0 ? $0 : nil }
        let rhr = Self.num(t["resting_heart_rate"]).map { Int($0.rounded()) }
        let nightHRV = Self.points((try? await client.get("night-hrv", ["date": day])) as? [String: Any])
        let hrv = Self.num(t["avg_overnight_hrv"])
            ?? (nightHRV.isEmpty ? nil : Double(nightHRV.map(\.bpm).reduce(0, +)) / Double(nightHRV.count))
        let skinDev = Self.num(t["skin_temp_deviation_c"])
        // The server reports efficiency as a percentage (98.2); NOOP stores asleep/in-bed as 0…1.
        let eff = Self.num(t["sleep_efficiency"]).map { $0 > 1 ? $0 / 100 : $0 }.flatMap { (0...1).contains($0) ? $0 : nil }

        var wroteDay = false
        // All-day SpO2 and 15-min steps keep today's numbers moving between Garmin's daily summaries: the
        // day's SpO2 falls back to the mean of its all-day points, and steps take the larger of the summary and
        // the summed 15-min intervals (the summary can lag the intervals on a running day). Some intraday
        // series start the evening before, so both are clipped to this local calendar day.
        let dayLo = Self.dayFmt.date(from: day).map { Int($0.timeIntervalSince1970) } ?? 0
        let inDay: ((ts: Int, bpm: Int)) -> Bool = { $0.ts >= dayLo && $0.ts < dayLo + 86_400 }
        // Only the two most recent days need these: a finished day's summary is final, and skipping them
        // keeps a full backfill from paying two extra slow requests per historical day.
        let spo2Pts = !recent ? [] : Self.points((try? await client.get("spo2-intraday", ["date": day])) as? [String: Any])
            .filter { inDay($0) && (70...100).contains($0.bpm) }
        let spo2 = Self.num(t["spo2"]) ?? (spo2Pts.isEmpty ? nil : Double(spo2Pts.map(\.bpm).reduce(0, +)) / Double(spo2Pts.count))
        let stepPts = !recent ? [] : Self.points((try? await client.get("steps-intraday", ["date": day])) as? [String: Any])
            .filter(inDay)
        let stepSum = stepPts.isEmpty ? nil : Double(stepPts.map(\.bpm).reduce(0, +))
        let steps = [Self.num(t["steps"]), stepSum].compactMap { $0 }.max()
        let hasAnything = [total, steps, spo2, Self.num(t["resting_heart_rate"]), hrv, skinDev].contains { $0 != nil }
        if hasAnything {
            let metric = DailyMetric(
                day: day, totalSleepMin: total, efficiency: eff,
                deepMin: deep, remMin: rem, lightMin: light,
                disturbances: Self.num(sleep["awakenings_count"]).map { Int($0) },
                restingHr: rhr, avgHrv: hrv,
                recovery: nil, strain: nil,          // NEVER the server's or Garmin's own scores
                exerciseCount: nil,
                spo2Pct: spo2, skinTempDevC: skinDev,
                respRateBpm: Self.num(t["respiration_rate"]),
                steps: steps.map { Int($0) }, activeKcalEst: nil)
            _ = try await store.upsertDailyMetrics([metric], deviceId: Self.deviceId)
            wroteDay = true
        }

        // Night window: Garmin's own bed/wake times and its per-segment hypnogram (deep/light/rem/awake,
        // stored with the canonical segment spelling "wake"). A day Garmin recorded no sleep for writes no
        // session: the night-HR series of such a day is daytime HR, and a span built from it showed up as a
        // stage-less "night" over a midday workout. Earlier builds stored exactly that, so stage-less
        // sessions of this source inside the day's window are removed first.
        var wroteSleep = false
        if let dayStart = Self.dayFmt.date(from: day).map({ Int($0.timeIntervalSince1970) }) {
            for s in try await store.sleepSessions(deviceId: Self.deviceId, from: dayStart - 43_200,
                                                   to: dayStart + 86_400, limit: 20) where s.stagesJSON == nil {
                _ = try await store.deleteSleepSession(deviceId: Self.deviceId, startTs: s.startTs)
            }
        }
        let levels: [[String: Any]] = (sleep["levels"] as? [[String: Any]] ?? []).compactMap { l in
            guard let s = Self.num(l["start_ms"]), let e = Self.num(l["end_ms"]), e > s,
                  let raw = (l["stage"] as? String)?.lowercased() else { return nil }
            let stage: String
            switch raw {
            case "deep", "light", "rem": stage = raw
            case "awake", "wake": stage = "wake"
            default: return nil
            }
            return ["start": Int(s / 1000), "end": Int(e / 1000), "stage": stage]
        }
        let stagesJSON = levels.isEmpty ? nil
            : (try? JSONSerialization.data(withJSONObject: levels)).flatMap { String(data: $0, encoding: .utf8) }
        let start = Self.num(sleep["sleep_start"]).map { Int($0 / 1000) }
        let end = Self.num(sleep["sleep_end"]).map { Int($0 / 1000) }
        if let start, let end, end - start >= 3_600, (total ?? 0) > 0 {
            let lowest = nightHR.map(\.bpm).min()
            _ = try await store.upsertSleepSessions([CachedSleepSession(
                startTs: start, endTs: end, efficiency: eff,
                restingHr: rhr ?? lowest, avgHrv: hrv, stagesJSON: stagesJSON)], deviceId: Self.deviceId)
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
        add("steps", steps)
        add("rhr", Self.num(t["resting_heart_rate"]))
        add("hrv", hrv)
        add("spo2", spo2)
        add("skin_temp_dev_c", skinDev)
        add("vo2max", Self.num(t["vo2max_cycling"]))
        add("sleep_total_min", total)
        add("sleep_deep_min", deep)
        add("sleep_light_min", light)
        add("sleep_rem_min", rem)
        add("ref_sleep_score", Self.num(t["sleep_score"]))
        if recent, let stress = (try? await client.get("stress-today", ["date": day])) as? [String: Any] {
            let vals = Self.points(stress).filter(inDay).map { Double($0.bpm) }
            if !vals.isEmpty { add("stress", vals.reduce(0, +) / Double(vals.count)) }
        }
        if !points.isEmpty { _ = try await store.upsertMetricSeries(points, deviceId: Self.deviceId) }

        return (wroteDay, wroteSleep, hrCount)
    }

    // MARK: - Helpers

    private func report(_ error: Error?, _ message: String? = nil) {
        failed = true
        if case GarminServerClient.Failure.unauthorized? = error as? GarminServerClient.Failure {
            GarminServerTokenStore.clear(); isConnected = false
        }
        statusText = message ?? (error as? LocalizedError)?.errorDescription ?? error?.localizedDescription
        live?.lastSyncError = statusText
    }

    /// Busy also keeps the screen awake on iOS so a long first backfill isn't frozen by auto-lock.
    private func setBusy(_ b: Bool) {
        busy = b
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = b
        #endif
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
}
