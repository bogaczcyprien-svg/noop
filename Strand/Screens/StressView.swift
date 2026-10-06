import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The shared explanation for activity-flagged hours on the Stress screen and hosted Today cards.
/// FORK CHANGE: these hours are no longer excluded from the line — `DaytimeStress` now scores
/// through real activity too, like WHOOP's own Stress monitor does, so the caption says so rather
/// than claiming a gap that no longer exists. Whole-phrase singular/plural variants keep the
/// sentence natural in every catalog locale.
func stressActivityMaskedHoursCaption(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1
        ? String(localized: "1 hour includes exercise — may read high from exertion, not stress.")
        : String(localized: "\(count) hours include exercise — may read high from exertion, not stress.")
}

/// Same shape, for hours excluded because they overlapped a detected sleep session (a sleep-in
/// morning crossing the 06:00 waking boundary) rather than the motion gate. See
/// `DaytimeStress.HourPoint.maskedForSleep`'s doc comment.
func stressSleepMaskedHoursCaption(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1
        ? String(localized: "1 hour excluded — you were still asleep.")
        : String(localized: "\(count) hours excluded — you were still asleep.")
}

// MARK: - Stress Monitor
//
// A clear, Whoop-style "Stress Monitor": one 0–3 number, a band (LOW/MEDIUM/HIGH),
// and a single plain-English line on *why*. The score is a transparent proxy for
// autonomic load.
//
// Source of the daily 0–3 value, in priority order:
//   1. The persisted `stress` metric series ("my-whoop") via `repo.series` — if a
//      day has a stored stress value we trust it.
//   2. Otherwise we DERIVE it from how today's resting HR / HRV sit against a
//      personal 30-day baseline. Stress shows up as HIGHER resting HR and LOWER
//      HRV, so we sum two z-scores and squash onto 0–3 with a logistic curve:
//
//        zRHR = (todayRHR − meanRHR) / sdRHR        // positive when RHR is UP
//        zHRV = (meanHRV − todayHRV) / sdHRV        // positive when HRV is DOWN
//        raw  = zRHR + zHRV                          // combined autonomic load
//        stress = 3 / (1 + e^(−raw))                // 0 calm · 1.5 baseline · 3 high
//
// Bands:  0–1 LOW · 1–2 MEDIUM · 2–3 HIGH.
//
// Everything is computed live from `repo.days` (+ the stored series), so the math
// is fully inspectable — see the "How this is computed" card at the bottom.

struct StressView: View {
    @EnvironmentObject var repo: Repository

    /// The stored 0–3 stress series ("my-whoop"), oldest→newest. Empty → derive.
    @State private var storedSeries: [(day: String, value: Double)] = []
    @State private var loaded = false
    /// Trend window for the chart (W/M/3M/6M/1Y/ALL).
    @State private var range: ExploreRange = .month

    /// The day the intraday timeline + context cards are showing. Defaults to today; the
    /// day-navigation arrows page this backward/forward (never past today). Fork addition,
    /// matching WHOOP's per-day Stress Monitor paging — NOOP's intraday read used to be
    /// today-only, so a user who missed checking in the moment had no way to look back.
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    /// The intraday stress read (hourly timeline + sustained-high flag) for `selectedDay`,
    /// computed from that day's banked HR + R-R via the SAME 0–3 proxy the daily score uses.
    /// Nil until the async read completes; `.empty` when the day has no usable intraday HR.
    @State private var daytime: DaytimeStress.Result?
    /// `selectedDay`'s own workouts (for the timeline's activity markers) and the "typical
    /// weekday" comparison's own async state. See `loadWeekdayBaseline` for the latter.
    @State private var dayWorkouts: [WorkoutRow] = []
    @State private var daySleepSpan: (start: Date, end: Date)?
    /// Continuous read through `daySleepSpan`, scored against the night's OWN reference — see
    /// `DaytimeStress.analyzeSleepWindow`'s doc comment. Merged with `daytime.timeline` for the
    /// chart so the line never simply stops at the shaded sleep band.
    @State private var sleepTimeline: [DaytimeStress.HourPoint] = []
    @State private var weekdayBaseline: WeekdayBaseline?
    /// Whether TODAY's intraday timeline is scored against the PERSONAL cross-day daytime baseline
    /// (`.baselineRelative`, once enough worn history exists) instead of the day's own calm hours
    /// (`.dayRelative`). Drives only the explanatory copy — the 0–3 scale + bands are identical either way.
    @State private var daytimeUsesPersonalBaseline = false
    /// Drives the Breathe sheet presented from the sustained-stress suggestion.
    @State private var showBreathe = false

    /// ADDITIVE, on-demand advanced readouts, computed live from the SAME day's R-R the
    /// daytime timeline already reads. These do NOT feed the 0..3 score or the timeline; they
    /// are two extra, clearly-labelled HRV lenses surfaced in their own card. Nil until the
    /// async read completes, and individually nil when their span/beat gates are not met.
    /// Baevsky Stress Index components (si / Mo / AMo / MxDMn).
    @State private var stressIndex: StressIndex.Components?
    /// Frequency-domain HRV bands (LF / HF / LF-HF / total power).
    @State private var freqHRV: HRVFreqDomain.Bands?

    /// Cached StressModel + the input signature it was built from. Rebuilding the
    /// model is expensive (z-score derivation + per-day date parsing over the full
    /// history), so we recompute it only when its inputs actually change — NOT on
    /// every body re-eval (hover / animation / 1 Hz HR ticks).
    @State private var model: StressModel?
    @State private var modelSignature: StressInputs?

    var body: some View {
        ScreenScaffold(title: "Stress", subtitle: "Autonomic load across your waking day",
                       // PERF (scroll): lazy column — byte-identical layout (LazyVStack == eager VStack
                       // alignment/spacing/header). The content is one inner eager VStack, so the staggered
                       // section reveal is unchanged; this only defers building that stack until it scrolls in.
                       lazy: true,
                       // The day-of-sky liquid backdrop, matching Today / Health / Live / Sleep / Trends: a
                       // fixed, full-bleed time-of-day sky behind the scroll content (does not scroll), so the
                       // Stress screen sits in the same liquid atmosphere as every other tab.
                       topBackground: liquidScaffoldSky()) {
            if let model {
                content(model)
            } else if !loaded {
                ComingSoon(what: "Reading your heart-rate variability and resting heart rate…")
            } else {
                emptyState
            }
        }
        .onAppear { rebuildModelIfNeeded() }
        .onChangeCompat(of: repo.days) { _ in rebuildModelIfNeeded() }
        .task(id: repo.refreshSeq) { await load() }
        .task(id: selectedDay) { await loadDaytime() }
    }

    /// True once `selectedDay` is today — the forward arrow disables here, and callers that
    /// want "now" rather than "end of the paged day" check this first.
    private var isViewingToday: Bool {
        Calendar.current.isDate(selectedDay, inSameDayAs: Date())
    }

    /// `sleepTimeline` restricted to `selectedDay`'s own [midnight, midnight+24h) — see the chart
    /// call site's comment for why a pre-midnight portion is dropped here rather than bunched.
    private var clippedSleepTimeline: [DaytimeStress.HourPoint] {
        let start = Calendar.current.startOfDay(for: selectedDay)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let lo = Int(start.timeIntervalSince1970), hi = Int(end.timeIntervalSince1970)
        return sleepTimeline.filter { $0.startTs >= lo && $0.startTs < hi }
    }

    private func load() async {
        storedSeries = await repo.series(key: "stress", source: "my-whoop")
        loaded = true
        rebuildModelIfNeeded()
        // `.task(id: selectedDay)` already covers day-paging, but it can fire before `model` exists
        // on first appear (both tasks start together), which would leave `weekdayBaseline` stuck nil
        // until the next page — this re-run, now that `model` is guaranteed built, is what catches
        // that first-load race rather than requiring a page to populate it.
        await loadDaytime()
    }

    /// Read `selectedDay`'s banked HR + R-R and build the intraday stress timeline. Local-day
    /// window [midnight, now-or-midnight-the-next-day]; the helper buckets it into waking hours
    /// and reuses the daily score's math, so this is the same proxy at a finer grain — never a
    /// new score. Also fetches that day's workouts (timeline activity markers) and sleep span
    /// (timeline shading) and kicks off the weekday-baseline comparison.
    private func loadDaytime() async {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: selectedDay)
        let from = Int(startOfDay.timeIntervalSince1970)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
        let to = isViewingToday ? Int(Date().timeIntervalSince1970) : Int(endOfDay.timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: startOfDay)

        async let workoutsTask = repo.workoutRows(days: max(1, daysAgo(selectedDay) + 2))
        async let sleepTask = repo.sleepSessions(from: from - 12 * 3600, to: to, limit: 4)
        let (allWorkouts, sleeps) = await (workoutsTask, sleepTask)
        dayWorkouts = allWorkouts.filter { $0.startTs < to && $0.endTs > from }
        // The primary (longest) session overlapping the day, for the shaded sleep band on the
        // chart — mirrors how the rest of the app picks "the night that belongs to this day".
        if let primary = sleeps.max(by: { ($0.endTs - $0.startTs) < ($1.endTs - $1.startTs) }) {
            daySleepSpan = (Date(timeIntervalSince1970: Double(primary.startTs)),
                            Date(timeIntervalSince1970: Double(primary.endTs)))
        } else {
            daySleepSpan = nil
        }

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        // Too few HR samples: empty the timeline AND clear the advanced readouts in lockstep. Without this
        // reset a later refresh that hits this path would leave the Advanced HRV card showing stale values
        // next to an empty timeline (the readouts are only recomputed past this guard).
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            daytime = .empty
            stressIndex = nil
            freqHRV = nil
            return
        }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        // Wrist accelerometer for the motion gate: an ambulatory hour is EXERTION, not stress, so it
        // is masked rather than scored (DaytimeStress). Same store read as R-R; empty on hardware or
        // imports with no gravity, which is exactly the "no masking, prior behaviour" degradation.
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)

        // Score today's hours against the PERSONAL cross-day daytime baseline ONLY when the user has
        // opted in (Settings → Experimental) AND enough worn history exists (Oura-style
        // `.baselineRelative`), else the day's own calm hours (`.dayRelative`, the default). The opt-in
        // gate is deliberate: the validated r≈0.6 margin is single-subject so far (#463), so this stays a
        // chooseable lens, not a silent default. The mode is resolved only AFTER the HR-count guard above,
        // so the trailing-history reads are never paid on a day with no scorable timeline — and are never
        // paid at all while the toggle is OFF (the default), keeping the read byte-identical to before.
        let mode = await DaytimeStressMode.selected(
            repo: repo,
            startOfToday: startOfDay,
            calendar: cal,
            personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled
        )
        if case .baselineRelative = mode { daytimeUsesPersonalBaseline = true }
        else { daytimeUsesPersonalBaseline = false }
        // includeTimeline: the SLIDING read, so the screen's line moves in half-hours instead of
        // stepping through whole clock hours (#2144). The scored unit is still a full hour; this only
        // decides how often that hour is re-read, so a thin ten minutes costs the windows that overlap
        // it rather than a whole hour of chart. The Today card and the widget have always asked for
        // this; the screen people actually study was the one still stepping. Twin of the Kotlin change.
        // #2181: this is pure, database-free computation over a whole local day of samples, and it used
        // to run inline on this view's (main) actor. `analyze` memoises behind a lock-guarded
        // `AnalyticsMemoCache`, so it is safe off the main actor and the Today card already reads its own
        // stress the same way. Moving it here is what lets the timeline be published — and drawn — before
        // the advanced readouts below are started.
        //
        // `runUnescalated`, NOT `await Task.detached(...).value`: awaiting a task from a @MainActor
        // caller makes it a child and hands it the caller's priority, so a `.utility` label on a
        // detached task is decorative and the work races the UI for cores anyway. StressDayCurve
        // learned that on this same issue; the continuation in UnescalatedWork is what keeps the
        // priority honest.
        // Exclude the night that belongs to this day from its OWN daytime stress read — a sleep-in
        // morning crossing the 06:00 waking boundary is still asleep, not a tense start to the day.
        // `daySleepSpan` was already fetched above for the chart's shading; reused here, not refetched.
        let sleepSpans: [(start: Int, end: Int)] = daySleepSpan.map {
            [(Int($0.start.timeIntervalSince1970), Int($0.end.timeIntervalSince1970))]
        } ?? []
        daytime = await runUnescalated(priority: .userInitiated) {
            DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, sleepSpans: sleepSpans,
                                  tzOffsetSeconds: tz, mode: mode,
                                  includeTimeline: true)
        }

        // Continuous coverage through the night too (#WHOOP-parity, at the user's explicit
        // request: "je veux que ça soit tout le temps"). Sleep is EXCLUDED from the daytime read
        // above on purpose (see `sleepSpans`'s comment) because scoring it against a waking
        // reference misreads ordinary sleep-stage HR/HRV swings as stress — so it needs its OWN
        // read, against its OWN night-only reference, not a widened daytime window. A dedicated
        // HR/R-R fetch scoped exactly to the sleep span (which usually starts the evening BEFORE
        // local midnight, outside `hr`/`rr` above) rather than reusing the day's own arrays.
        if let span = daySleepSpan {
            let sleepFrom = Int(span.start.timeIntervalSince1970)
            let sleepTo = Int(span.end.timeIntervalSince1970)
            let sleepHR = await repo.hrSamples(from: sleepFrom, to: sleepTo, limit: 200_000)
            let sleepRR = await repo.rrIntervals(from: sleepFrom, to: sleepTo, limit: 200_000)
            sleepTimeline = await runUnescalated(priority: .userInitiated) {
                DaytimeStress.analyzeSleepWindow(hr: sleepHR, rr: sleepRR,
                                                 sleepSpan: (sleepFrom, sleepTo),
                                                 tzOffsetSeconds: tz)
            }
        } else {
            sleepTimeline = []
        }

        // ADDITIVE advanced readouts, computed on-demand from the SAME `rr` (no extra fetch, no
        // DB / schema change, and no effect on the 0..3 score above). Each engine returns nil when
        // its own gate is not met (Baevsky needs >= 20 clean beats; freq-HRV needs >= 60 s span),
        // in which case its row is simply hidden.
        // A SECOND hop on purpose (#2181). `HRVFreqDomain` is a Lomb-Scargle periodogram: its cost is
        // (clean beats x frequency-grid steps) with a transcendental per step, and it takes whatever beat
        // count the day's read returned — the store read above is bounded at 200 000, this is not bounded
        // at all. On a live-banked day that is seconds of arithmetic, and run inline it held the main
        // thread for all of them, which is why the screen stayed blank rather than drawing the timeline it
        // already had. Both engines are pure statics over the same `rr`, so they compute together off the
        // main actor and publish when done; their card is hidden until then, exactly as it is when a gate
        // is unmet. Same `runUnescalated` reasoning as above, and the default `.utility` is real here
        // because nothing escalates it: this is the phase that must yield to the UI.
        let advanced = await runUnescalated {
            (index: StressIndex.components(rr: rr), freq: HRVFreqDomain.freqDomain(rr: rr))
        }
        stressIndex = advanced.index
        freqHRV = advanced.freq

        // The "vs a typical <weekday>" comparison (#WHOOP-parity): a separate, slower read, so it
        // never blocks the timeline/advanced-readouts above from appearing first. See
        // `loadWeekdayBaseline`'s doc comment for what it computes and why it is bounded.
        weekdayBaseline = nil
        weekdayBaseline = await loadWeekdayBaseline(for: selectedDay)
    }

    /// Days between `day` and today (0 for today, 1 for yesterday, …) — used to size the
    /// `workoutRows` lookback so paging back in history still finds that day's workouts without
    /// fetching the whole multi-year default every time.
    private func daysAgo(_ day: Date) -> Int {
        let cal = Calendar.current
        let a = cal.startOfDay(for: day), b = cal.startOfDay(for: Date())
        return max(0, cal.dateComponents([.day], from: a, to: b).day ?? 0)
    }

    /// Recovers the LOCAL calendar day a `fullTrend` date names, by round-tripping it through the
    /// SAME UTC "yyyy-MM-dd" formatter that built it (lossless — it only ever reads the key back
    /// out) and then reading those year/month/day components into the LOCAL calendar directly,
    /// never through a UTC *instant* a local calendar would reinterpret. `Calendar.startOfDay(for:
    /// utcMidnightInstant)` would get this wrong by a full day for any negative-UTC-offset user.
    private func localDayStart(fromUTCDayKeyDate utcDate: Date) -> Date {
        let cal = Calendar.current
        let parts = Self.dayKeyFormatter.string(from: utcDate).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return cal.startOfDay(for: utcDate) }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return cal.date(from: comps) ?? cal.startOfDay(for: utcDate)
    }

    /// "vs a typical <weekday>" (#WHOOP-parity): `selectedDay` compared against the AVERAGE of its
    /// own last few same-weekday occurrences, not a generic 30-day pool — a Friday after a long
    /// week reads differently from a Friday after a short one, and averaging every weekday together
    /// would wash that out. Two lenses, each built from data NOOP already trusts rather than a new
    /// physiological model:
    ///   - Sleep: averages `StressModel.fullTrend`'s already-computed nightly scores (cheap — no
    ///     extra store read, since that score is already sleep-session-scoped; see
    ///     `primarySessionRestingHR`'s doc comment in AnalyticsEngine).
    ///   - Non-activity: re-runs the SAME `DaytimeStress.analyze` pass (totals only, no timeline)
    ///     over each matched day's own HR/R-R/gravity. Bounded to `weekdayLookback` days and run
    ///     sequentially (not a `TaskGroup`) — this is a once-per-navigation read, not a hot path,
    ///     and sequential keeps it one store-read-shaped query at a time rather than bursting
    ///     `weekdayLookback` of them at the actor together.
    private static let weekdayLookback = 4

    private func loadWeekdayBaseline(for day: Date) async -> WeekdayBaseline? {
        guard let model else { return nil }
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: day)
        // `fullTrend`'s dates come from `StressModel.dayParser` (UTC-midnight per day key) —
        // comparing against `cal.startOfDay(for: day)` (LOCAL midnight) would silently misalign
        // near the boundary for any non-UTC timezone, so `day` is round-tripped through the SAME
        // UTC day-key formatter before the comparison, not through the local calendar.
        let dayUTCMidnight = Self.dayKeyFormatter.date(from: Self.dayKeyFormatter.string(from: day)) ?? day
        let pastSameWeekday = model.fullTrend
            .filter { cal.component(.weekday, from: $0.date) == weekday && $0.date < dayUTCMidnight }
            .suffix(Self.weekdayLookback)
        guard !pastSameWeekday.isEmpty else { return nil }

        let sleepAvg = pastSameWeekday.map(\.value).reduce(0, +) / Double(pastSameWeekday.count)

        var splits: [BandSplit] = []
        for point in pastSameWeekday {
            if let totals = await dayNonActivityTotals(for: point.date) {
                splits.append(BandSplit(totals: totals))
            }
        }
        let nonActivityAvg: BandSplit? = splits.isEmpty ? nil : BandSplit(
            low: splits.map(\.low).reduce(0, +) / Double(splits.count),
            mid: splits.map(\.mid).reduce(0, +) / Double(splits.count),
            high: splits.map(\.high).reduce(0, +) / Double(splits.count)
        )

        return WeekdayBaseline(
            weekdayLabel: Self.weekdaySymbol(cal, weekday),
            sleepScoreAvg: sleepAvg, sleepSampleDays: pastSameWeekday.count,
            nonActivitySplit: nonActivityAvg, nonActivitySampleDays: splits.count
        )
    }

    /// Re-derives one past day's Calm/Moderate/High split — the totals-only half of what
    /// `loadDaytime` does for `selectedDay`, without the sliding timeline (nothing here draws a
    /// line, so there is no reason to pay for one). `day` comes from `fullTrend`, whose dates are
    /// UTC-midnight-per-day-key (see `loadWeekdayBaseline`'s comment) — `localDayStart` recovers
    /// the LOCAL calendar day that key actually names instead of asking a local calendar for the
    /// start of a UTC instant, which drifts a full day off `selectedDay`'s own window for any
    /// negative-UTC-offset timezone.
    private func dayNonActivityTotals(for day: Date) async -> StressTotals? {
        let cal = Calendar.current
        let startOfDay = localDayStart(fromUTCDayKeyDate: day)
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int((cal.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay).timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: startOfDay)

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        guard hr.count >= DaytimeStress.minHourHRSamples else { return nil }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)
        // Same sleep exclusion `loadDaytime` applies to `selectedDay` — without it, a past day in
        // the weekday-baseline average would unfairly look worse purely for having had a sleep-in
        // morning scored as tense, which the paged day itself no longer does.
        let sleeps = await repo.sleepSessions(from: from - 12 * 3600, to: to, limit: 4)
        let sleepSpans: [(start: Int, end: Int)] = sleeps.map { ($0.startTs, $0.endTs) }
        let mode = await DaytimeStressMode.selected(
            repo: repo, startOfToday: startOfDay, calendar: cal,
            personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled
        )
        let result = await runUnescalated(priority: .utility) {
            DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, sleepSpans: sleepSpans,
                                  tzOffsetSeconds: tz, mode: mode,
                                  includeTimeline: false)
        }
        guard !result.scored.isEmpty else { return nil }
        return StressTotals(hours: result.hours)
    }

    /// Localized weekday name ("Friday" / "vendredi"), from a `Calendar.Component.weekday` value
    /// (1 = Sunday … 7 = Saturday) via `DateFormatter.weekdaySymbols`, which is already indexed the
    /// same way and already localized — no hand-rolled name table to keep in sync with the catalog.
    private static func weekdaySymbol(_ cal: Calendar, _ weekday: Int) -> String {
        let symbols = DateFormatter().weekdaySymbols ?? []
        let idx = weekday - 1
        guard symbols.indices.contains(idx) else { return "" }
        return symbols[idx]
    }

    /// Recompute the cached `StressModel` only when (repo.days, storedSeries)
    /// actually changed since the last build. Equality is an O(n) value compare,
    /// far cheaper than the model rebuild it guards.
    private func rebuildModelIfNeeded() {
        let signature = StressInputs(days: repo.days, stored: storedSeries)
        guard signature != modelSignature else { return }
        modelSignature = signature
        model = StressModel(days: repo.days, stored: storedSeries)
    }

    // MARK: Loaded content

    @ViewBuilder
    private func content(_ model: StressModel) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {

            // 0. DAY NAVIGATOR (#WHOOP-parity) — pages the hero + intraday timeline + the two
            //    context cards below between past days. Never past today.
            dayNavigatorHeader
                .staggeredAppear(index: 0)

            // 1. HERO — the liquid stress-level vessel + band + one plain-English line, all in one card.
            heroCard(model)
                .staggeredAppear(index: 1)

            // 1b. ADVANCED HRV readouts (additive, on-demand). A separate, clearly-labelled card
            //     that appears only when at least one engine returned a value. It sits BELOW the
            //     hero and never alters the hero, the markers or the timeline.
            if hasAdvancedReadouts {
                advancedReadoutsCard()
                    .staggeredAppear(index: 2)
            }

            // 2. Today's numbers — uniform tiles in one grid.
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Today", overline: "Markers", trailing: String(localized: "vs 30-day baseline"))
                tileGrid(model)
            }
            .staggeredAppear(index: 2)

            // 3. Intraday timeline (the paged day) + the "Outside activity" / "Sleep" context
            //    cards — when in the day stress ran high, + a passive Breathe suggestion when the
            //    recent hours stay elevated.
            // #2535: THREE states, not two. `daytime` is nil only while the read is still running, and this
            // used to render nothing then, so a fold that takes seconds looked exactly like a day with no
            // data. An empty `scored` after the read is a fact about the day and still stays silent.
            if daytime == nil {
                daytimeLoading()
                    .staggeredAppear(index: 3)
            } else if let daytime, !daytime.scored.isEmpty {
                daytimeSection(daytime)
                    .staggeredAppear(index: 3)
            }

            // 4. Trend over the chosen window.
            trendSection(model)
                .staggeredAppear(index: 4)

            // 5. Transparency — how the number is built.
            methodologyCard(model)
                .staggeredAppear(index: 5)
        }
        // The sustained-stress suggestion opens the existing Breathe trainer in a sheet —
        // in-app and passive (no alert / notification), inheriting the app environment.
        .sheet(isPresented: $showBreathe) {
            NavigationStack {
                BreathingView()
                    .toolbar {
                        ToolbarItem {
                            Button("Done") { showBreathe = false }
                        }
                    }
            }
            #if os(macOS)
            .frame(width: 520, height: 760)
            #endif
        }
    }

    // MARK: 3 · Daytime timeline (intraday, same 0–3 proxy)

    /// The intraday timeline while its read is still running (#2535).
    ///
    /// Deliberately NOT the "no stress history" note: that is a conclusion, this says the answer is still
    /// being computed, which is what a caller waiting on the thirty-day fold needs to see. Keeps the header
    /// and tint `daytimeSection` uses, so the section does not appear out of nowhere when the read lands; the
    /// height is approximate, not equal, since the real card carries a chart. Twin of the Kotlin
    /// `StressDaytimeLoading`.
    @ViewBuilder
    private func daytimeLoading() -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Today's Timeline", overline: "Intraday")
            NoopCard(tint: StressRamp.calm) {
                Text("Reading today's heart rate…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func daytimeSection(_ day: DaytimeStress.Result) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader(isViewingToday ? "Today's Timeline" : "Timeline",
                              overline: "Intraday", trailing: timelineTrailing(day))

                NoopCard(tint: StressRamp.calm) {
                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        HStack {
                            Text("Autonomic load through the day").strandOverline()
                            Spacer()
                            // The peak of what is DRAWN, not of the whole hours (#2144). A sliding window
                            // can exceed both hourly neighbours when the busy stretch straddles a boundary,
                            // so `day.peak` would caption the line with a number below its visible maximum.
                            // Everything that COUNTS hours still reads `hours`; a maximum is not a count.
                            let drawnPeak = day.timeline.filter { $0.level != nil }
                                .max { ($0.level ?? 0) < ($1.level ?? 0) }
                            if let peak = drawnPeak, let lvl = peak.level {
                                Text("peak \(StressTrace.formatLevel(lvl)) · \(hourLabel(peak.hour))")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StressRamp.color(lvl))
                            }
                        }

                        // README screen-9: the day autonomic-load LINE, drawn with the same
                        // 3-stop blue→green→amber WHOOP gradient as the gauge. Full-24h axis
                        // (#WHOOP-parity): `dayStart` set positions the waking line by real
                        // time-of-day and draws the night's sleep shading + any workout markers in
                        // the same system, instead of the bare index-packed layout.
                        // The SLIDING series, not the bare hours (#2144). Everything that COUNTS hours
                        // keeps reading `hours`: the totals bar's shares still have to sum to the day.
                        // Only the line and its ruler follow the finer read.
                        // `sleepTimeline` merged in (#WHOOP-parity, explicit request: "je veux que ça
                        // soit tout le temps") so the line runs continuously through the shaded sleep
                        // band instead of stopping at it — each half scored against its OWN reference
                        // (see `analyzeSleepWindow`'s doc comment), just drawn as one curve. Clipped to
                        // THIS day's own [midnight, midnight+24h): a session starting the evening
                        // before (the usual case) also carries pre-midnight points, which belong on
                        // YESTERDAY's chart at its own right edge, not bunched onto today's left edge.
                        DaytimeLoadLine(
                            hours: (day.timeline + clippedSleepTimeline).sorted { $0.startTs < $1.startTs },
                            dayStart: Calendar.current.startOfDay(for: selectedDay),
                            sleepSpan: daySleepSpan,
                            activityMarkers: dayWorkouts.map {
                                (Date(timeIntervalSince1970: Double($0.startTs)),
                                 Date(timeIntervalSince1970: Double($0.endTs)))
                            }
                        )

                        // Hour ruler under the line (first / midday / last covered hour).
                        if let lo = day.timeline.first?.hour, let hi = day.timeline.last?.hour {
                            HStack {
                                Text(hourLabel(lo)).font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                Spacer()
                                Text(hourLabel((lo + hi) / 2)).font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                Spacer()
                                Text(hourLabel(hi)).font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }

                        Text(daytimeTimelineCaption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Sustained-high suggestion — only when the recent run stays in the HIGH band.
                if day.sustainedHigh { sustainedBreatheCard(day) }
            }

            // "Hors activité" (#WHOOP-parity): the SAME Calm/Moderate/High split, now its own
            // clearly-labelled card — split out of the chart card above — plus a "vs a typical
            // <weekday>" comparison when enough history exists.
            nonActivityContextCard(day)

            // "Sommeil" (#WHOOP-parity): the night's own vitals-based score (same `StressModel`
            // math the hero uses, resolved for `selectedDay` specifically), not a new signal.
            sleepContextCard()
        }
    }

    /// "avg 1.4 · 9h" summary for the timeline header, from the scored hours.
    private func timelineTrailing(_ day: DaytimeStress.Result) -> String {
        let n = day.scored.count
        guard let mean = day.dayMean else { return String(localized: "\(n)h") }
        return String(localized: "avg \(StressTrace.formatLevel(mean)) · \(n)h")
    }

    /// The timeline's explanatory line, honest about WHICH reference each hour was scored against —
    /// the personal cross-day baseline (`.baselineRelative`) or the day's own calm hours (`.dayRelative`).
    /// Explicit `LocalizedStringKey` so BOTH variants stay in the string catalog (a ternary inside
    /// `Text(_:)` would resolve to the verbatim, non-localized `String` overload).
    private var daytimeTimelineCaption: LocalizedStringKey {
        daytimeUsesPersonalBaseline
            ? "The line is each waking hour's 0-3 proxy, scored against your personal daytime baseline (how your own days usually run). The bar below splits your day into calm, moderate and high stress time."
            : "The line is each waking hour's 0-3 proxy, scored against your own calm hours today. The bar below splits your day into calm, moderate and high stress time."
    }

    /// A passive, in-app nudge to run a Breathe session after a sustained high-stress run.
    /// No notification — just a card with a CTA that opens the existing trainer.
    private func sustainedBreatheCard(_ day: DaytimeStress.Result) -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.rowSpacing) {
                    Image(systemName: "lungs.fill")
                        .foregroundStyle(StressRamp.calm)
                    Text("Sustained high stress").strandOverline()
                    Spacer()
                    StatePill("\(day.sustainedRun)h elevated", tone: .warning, showsDot: true)
                }
                Text("Your last \(day.sustainedRun) hours have stayed in the high band. A few minutes of paced breathing can help downshift your nervous system.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Start a Breathe session", systemImage: "wind",
                           kind: .primary, fullWidth: true) {
                    showBreathe = true
                }
            }
        }
        .softCardTransition()
    }

    // MARK: 3b · "Hors activité" context card (#WHOOP-parity)

    /// The chart card's own Calm/Moderate/High split, pulled out into its own labelled card (WHOOP
    /// calls this "stress outside of exercise and sleep") plus a same-weekday comparison bar when
    /// `weekdayBaseline` has one. Nothing here is a new signal: `day.hours` is the identical
    /// activity-masked split the chart above already draws from.
    private func nonActivityContextCard(_ day: DaytimeStress.Result) -> some View {
        let totals = StressTotals(hours: day.hours)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Outside Activity", overline: "Context")
            NoopCard(tint: StressRamp.calm) {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    HStack {
                        Image(systemName: "figure.stand")
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("Outside activity").strandOverline()
                    }
                    Text("Stress felt outside of exercise and sleep.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)

                    StressTotalsBar(totals: totals)

                    if let baseline = weekdayBaseline, let typical = baseline.nonActivitySplit {
                        Divider().overlay(StrandPalette.hairline)
                        Text("vs a typical \(baseline.weekdayLabel) (\(baseline.nonActivitySampleDays)d avg)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        ComparisonBandBar(today: BandSplit(totals: totals), typical: typical)
                    }

                    if let maskedCaption = stressActivityMaskedHoursCaption(day.activityMaskedHours) {
                        Text(maskedCaption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let sleepCaption = stressSleepMaskedHoursCaption(day.sleepMaskedHours) {
                        Text(sleepCaption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: 3c · "Sommeil" context card (#WHOOP-parity)

    /// The night's OWN vitals-based score for `selectedDay` — literally `StressModel`'s existing
    /// math (RHR up / HRV down vs. a 30-day baseline), which is already sleep-session-scoped (see
    /// `primarySessionRestingHR`'s doc comment), resolved via `StressModel.detail(forDayKey:)`
    /// instead of invented as a new per-epoch sleep signal. Hidden entirely when that day has no
    /// derivable score — nothing to show honestly beats a fabricated one.
    @ViewBuilder
    private func sleepContextCard() -> some View {
        let key = Self.localDayKeyFormatter.string(from: selectedDay)
        if let detail = StressModel.detail(forDayKey: key, days: repo.days, stored: storedSeries) {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Sleep", overline: "Context")
                NoopCard(tint: StressRamp.calm) {
                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        HStack {
                            Image(systemName: "moon.fill")
                                .foregroundStyle(StrandPalette.textTertiary)
                            Text("Sleep").strandOverline()
                            Spacer()
                            StatePill("\(detail.band.title)", tone: detail.band.tone, showsDot: true)
                        }
                        Text("Stress felt during sleep.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)

                        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                            Text(StressTrace.formatLevel(detail.score))
                                .font(StrandFont.rounded(28, weight: .bold))
                                .foregroundStyle(StressRamp.color(detail.score))
                            Text("of 3")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Text(detail.explanation)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let baseline = weekdayBaseline, let typicalScore = baseline.sleepScoreAvg {
                            Divider().overlay(StrandPalette.hairline)
                            HStack {
                                Text("vs a typical \(baseline.weekdayLabel) (\(baseline.sleepSampleDays)d avg)")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                Spacer()
                                Text(StressTrace.formatLevel(typicalScore))
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StressRamp.color(typicalScore))
                            }
                        }
                    }
                }
            }
        }
    }

    /// Hour-of-day label following the device's locale + 12-/24-hour preference ("2 PM" / "14 Uhr"),
    /// instead of a hard-coded English "am/pm" (which read "3 pm" for 24-hour locales like German).
    private func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: 0 · Day navigator (#WHOOP-parity)

    /// Previous/next-day paging for the hero + intraday timeline + the two context cards. The
    /// forward arrow disables on today rather than wrapping into the future, which NOOP has no
    /// data for and should never imply it does.
    private var dayNavigatorHeader: some View {
        HStack {
            Button {
                changeDay(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(String(localized: "Previous day"))

            Spacer()
            Text(selectedDay, format: .dateTime.weekday(.wide).day().month(.abbreviated))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()

            Button {
                changeDay(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isViewingToday ? StrandPalette.textTertiary : StrandPalette.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .disabled(isViewingToday)
            .accessibilityLabel(String(localized: "Next day"))
        }
    }

    private func changeDay(by delta: Int) {
        let cal = Calendar.current
        guard let moved = cal.date(byAdding: .day, value: delta, to: selectedDay) else { return }
        let clamped = min(cal.startOfDay(for: moved), cal.startOfDay(for: Date()))
        selectedDay = clamped
    }

    // MARK: 1 · Hero — the liquid stress-level vessel.
    //
    // The 0–3 stress score reads as the signature liquid gauge: a LiquidVessel that fills to score/3
    // and is tinted by the live band (calm blue → steady green → tense amber), with the count-up value +
    // "of 3" over it (the Today HeroScoreCell / Live BPM-gauge idiom). The band pill sits top-trailing and
    // one plain-English line explains the number below. Frosted card, liquid finish.
    //
    // Day-paged (#WHOOP-parity): while `selectedDay` is today this is the same LIVE score it always
    // was; paged to a past day it resolves THAT day's own score via `StressModel.detail(forDayKey:)`
    // rather than silently continuing to show today's number under a different day's label — the
    // "two readouts of one fact must not disagree" rule applies to a date header + a value beneath it
    // exactly as much as to two cards. A day with no derivable signal says so, not a guess.

    /// UTC-fixed — ONLY for round-tripping a `StressModel.fullTrend` date (itself built on a
    /// UTC-midnight-per-day-key basis) back to the key it came from, consistently with itself.
    /// Never for turning `selectedDay` (a genuinely LOCAL midnight) into a key — see
    /// `localDayKeyFormatter` for that; using this one there shifts the calendar day by the
    /// device's UTC offset for any non-UTC timezone.
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Device-timezone — for turning `selectedDay` (LOCAL midnight) into the "yyyy-MM-dd"
    /// `DailyMetric.day` key it actually names, so `StressModel.detail(forDayKey:)` looks up the
    /// day the navigator is actually showing rather than the UTC-shifted neighbour of it.
    private static let localDayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private enum HeroDisplay {
        case live(score: Double, band: StressBand, explanation: String)
        case past(score: Double, band: StressBand, explanation: String)
        case noData
    }

    private func heroDisplay(_ model: StressModel) -> HeroDisplay {
        guard !isViewingToday else { return .live(score: model.score, band: model.band, explanation: model.explanation) }
        let key = Self.localDayKeyFormatter.string(from: selectedDay)
        guard let detail = StressModel.detail(forDayKey: key, days: repo.days, stored: storedSeries) else {
            return .noData
        }
        return .past(score: detail.score, band: detail.band, explanation: detail.explanation)
    }

    private func heroCard(_ model: StressModel) -> some View {
        let display = heroDisplay(model)
        return NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    Text("Stress monitor").strandOverline()
                    Spacer()
                    if case .live = display {
                        StatePill("LIVE", tone: .accent, showsDot: true)
                    }
                    switch display {
                    case .live(_, let band, _), .past(_, let band, _):
                        StatePill("\(band.title)", tone: band.tone, showsDot: true)
                    case .noData:
                        EmptyView()
                    }
                }

                switch display {
                case .live(let score, let band, let explanation), .past(let score, let band, let explanation):
                    HStack(alignment: .center, spacing: NoopMetrics.space5) {
                        // The stress-level vessel: fills to score/3, tinted to the live band, the value
                        // counting up over it. Taps splash the gauge (the numeral is hit-transparent).
                        StressHeroGauge(score: score, tint: StressRamp.color(score))

                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text(band.title)
                                .font(StrandFont.overline)
                                .tracking(StrandFont.overlineTracking)
                                .foregroundStyle(StressRamp.color(score))
                            // One plain-English line beside the gauge.
                            Text(explanation)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                case .noData:
                    Text("No resting HR or HRV for this day, so there's nothing to score it against.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    // MARK: 1b · Advanced HRV readouts (additive, on-demand)
    //
    // Two extra, clearly-labelled lenses on the SAME day's R-R the timeline already reads, surfaced
    // in their own card so they are visibly separate from the 0..3 monitor. Each row is shown only
    // when its engine produced a value (the engines self-gate on clean-beat count / record span),
    // and the whole card is gated by `hasAdvancedReadouts`. Nothing here feeds the score.

    /// True when at least one advanced readout is presentable (an SI value, or an LF/HF ratio, or
    /// at least the HF power). Drives whether the advanced card is shown at all.
    private var hasAdvancedReadouts: Bool {
        if stressIndex != nil { return true }
        if let f = freqHRV, f.lfhf != nil || f.hf > 0 { return true }
        return false
    }

    @ViewBuilder
    private func advancedReadoutsCard() -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack {
                    Text("Advanced HRV").strandOverline()
                    Spacer()
                    Text("on demand · today's R-R")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                    alignment: .leading,
                    spacing: NoopMetrics.gap
                ) {
                    // Baevsky Stress Index, a whole number; higher means a more rigid, stressed rhythm.
                    if let si = stressIndex {
                        StatTile(
                            label: "Baevsky Stress Index",
                            value: "\(Int(si.si.rounded()))",
                            caption: String(localized: "Autonomic rigidity from your heart-rate rhythm. Higher means a more rigid, stressed rhythm."),
                            accent: StressRamp.tense
                        )
                    }

                    // Frequency-domain HRV: prefer the LF/HF ratio; if the span was too short for
                    // LF (lfhf nil) fall back to the HF (rest) band power so the lens still reads.
                    if let f = freqHRV {
                        if let ratio = f.lfhf {
                            StatTile(
                                label: "Autonomic balance (LF/HF)",
                                value: StressTrace.formatRatio(ratio),
                                caption: String(localized: "Sympathetic vs parasympathetic tone from frequency-domain HRV. Higher leans sympathetic (stress-ward)."),
                                accent: StressRamp.steady
                            )
                        } else if f.hf > 0 {
                            StatTile(
                                label: "HF power",
                                value: "\(Int(f.hf.rounded()))",
                                caption: String(localized: "Parasympathetic (rest) band of your HRV."),
                                accent: StressRamp.steady
                            )
                        }
                    }
                }

                Text("These are extra, on-demand HRV lenses computed from today's R-R intervals. They are informational and do not change the stress score above.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: 2 · Today's tiles (uniform grid)

    private func tileGrid(_ model: StressModel) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
            alignment: .leading,
            spacing: NoopMetrics.gap
        ) {
            // Today's stress value, with its band as the caption.
            StatTile(
                label: "Stress",
                value: StressTrace.formatLevel(model.score),
                caption: String(localized: "of 3 · \(model.band.title)"),
                accent: StressRamp.color(model.score),
                sparkline: model.sparkValues.count > 1 ? model.sparkValues : nil,
                sparkColor: StressRamp.color(model.score)
            )
            // Resting HR — an INCREASE is the stressful direction.
            markerTile(
                label: "Resting HR",
                value: model.rhrToday.map { String(localized: "\($0) bpm") } ?? "—",
                delta: model.rhrDelta,
                accent: StrandPalette.metricRose,
                higherIsStress: true
            )
            // HRV — a DECREASE is the stressful direction.
            markerTile(
                label: "HRV",
                value: model.hrvToday.map { String(localized: "\(Int($0.rounded())) ms") } ?? "—",
                delta: model.hrvDelta,
                accent: StrandPalette.metricPurple,
                higherIsStress: false
            )
            // Estimated calm time — share of recent days spent in the LOW band.
            StatTile(
                label: "Calm time",
                value: model.calmTimeValue,
                caption: model.calmTimeCaption,
                accent: StressRamp.calm
            )
        }
    }

    /// A vs-baseline marker as a fixed-height StatTile. The delta is tinted by
    /// whether the move is toward stress (warning) or recovery (positive).
    private func markerTile(label: LocalizedStringKey, value: String, delta: Double?, accent: Color, higherIsStress: Bool) -> some View {
        let deltaText: String?
        let deltaColor: Color
        // NO CHIP for a missing delta, rather than a claim we cannot make (#2145). It is nil when
        // today has no reading or there is no 30-day baseline to stand one against, and both fell
        // through to the at-baseline chip: a tile with no reading read "— at baseline", and a
        // first-week tile put a reading exactly on a baseline that did not exist yet. StatTile draws
        // the pill only for a non-nil delta, so nil is already the way to say nothing here.
        if delta == nil {
            deltaText = nil
            deltaColor = StrandPalette.textTertiary
        } else if let delta, abs(delta) >= 0.5 {
            let up = delta > 0
            let isStressful = (up == higherIsStress)
            deltaText = String(localized: "\(up ? "+" : "−")\(Int(abs(delta).rounded())) vs base")
            deltaColor = isStressful ? StrandPalette.statusWarning : StrandPalette.statusPositive
        } else {
            deltaText = String(localized: "at baseline")
            deltaColor = StrandPalette.textTertiary
        }
        return StatTile(
            label: label,
            value: value,
            caption: nil,
            accent: accent,
            delta: deltaText,
            deltaColor: deltaColor
        )
    }

    // MARK: 3 · Trend (range-controlled)

    @ViewBuilder
    private func trendSection(_ model: StressModel) -> some View {
        let points = windowedTrend(model)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stress Trend", overline: "History", trailing: range.name)
            if points.count >= 2 {
                let avg = points.map(\.value).reduce(0, +) / Double(points.count)
                // Axis top = highest reading rounded up, plus a little headroom, so a peak curve and
                // the top axis label clear the plot clip (#974). Floor of 1 keeps a flat calm history
                // from collapsing to a zero-height axis. The gradient stays on the full 0–3 scale
                // because TrendChart keys its colors off `valueRange`, not this domain.
                let peak = (points.map(\.value).max() ?? 3).rounded(.up)
                let yTop = max(1, peak + 0.3)
                ChartCard(
                    title: "Stress · \(range.label)",
                    subtitle: String(localized: "Daily 0-3 proxy"),
                    trailing: String(localized: "avg \(StressTrace.formatLevel(avg))"),
                    tint: StressRamp.calm
                ) {
                    TrendChart(
                        points: points,
                        gradient: StressRamp.gradient,
                        valueRange: 0...3,
                        showsArea: true,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { StressTrace.formatLevel($0) },
                        accessibilityLabel: String(localized: "Stress trend"),
                        yDomain: 0...yTop
                    )
                } footer: {
                    ChartFooter([
                        ("Today", StressTrace.formatLevel(model.score)),
                        ("Average", StressTrace.formatLevel(avg)),
                        ("Days", "\(points.count)"),
                    ])
                }
                // The one segmented control. Its eight options use the shared adaptive-width mode so
                // the control stays inside the same page gutter as the chart on compact iPhones.
                SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                     adaptsToAvailableWidth: true) { $0.label }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                NoopCard(tint: StressRamp.calm) {
                    Text("Not enough recent days to chart a trend yet. Import a history or keep wearing your strap.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// The full daily proxy trend, sliced to the selected trailing window. Falls
    /// back to ALL when the trailing slice holds < 2 points.
    private func windowedTrend(_ model: StressModel) -> [TrendPoint] {
        let all = model.fullTrend
        guard let days = range.days, let last = all.last?.date else { return all }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        let slice = all.filter { $0.date >= cutoff }
        return slice.count >= 2 ? slice : all
    }

    // MARK: 4 · Methodology (transparency)

    private func methodologyCard(_ model: StressModel) -> some View {
        NoopCard(tint: StressRamp.calm) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("How this is computed").strandOverline()
                Text(model.usingStored
                     ? "Today's value is your recorded daily stress score (0-3)."
                     : "Stress is derived from two autonomic signals.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("We compare today's resting heart rate and HRV to your own 30-day baseline. A higher-than-usual resting HR and a lower-than-usual HRV both push the score up, classic signs the body is activated. The combined shift is mapped onto a 0-3 scale: 0 is calm, 1.5 sits at your baseline, 3 is highly activated.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The intraday line keeps running through sleep, but scored against that night's OWN calmest stretch rather than the day's — sleep's normal HR/HRV swings (deep sleep vs. REM, the natural rise near waking) are not what the waking reference is built to read, so each half gets a reference that actually fits it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider().overlay(StrandPalette.hairline)
                HStack(spacing: 0) {
                    bandLegend("0-1", String(localized: "LOW"), StressRamp.calm)
                    bandLegend("1-2", String(localized: "MEDIUM"), StressRamp.steady)
                    bandLegend("2-3", String(localized: "HIGH"), StressRamp.tense)
                }
            }
        }
    }

    private func bandLegend(_ range: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
                Text(range).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ComingSoon(what: "No stress history yet. Import your WHOOP export in Data Sources to see it.")
    }
}

// MARK: - Stress hero gauge (liquid vessel + count-up score)

/// The stress-level vessel: a LiquidVessel filled to `score`/3 and tinted to the live band, with the
/// 0–3 value counting up over it and "of 3" beneath (the Today HeroScoreCell / Live BPM-gauge idiom).
/// CountUpText self-animates the number roll; the numeral is hit-transparent so a tap reaches the
/// vessel and splashes it.
private struct StressHeroGauge: View {
    let score: Double        // 0–3
    let tint: Color

    private var frac: Double { max(0, min(1, score / 3.0)) }

    var body: some View {
        ZStack {
            LiquidVessel(value: frac, tint: tint, animated: true)
                .frame(width: 104, height: 104)
            VStack(spacing: 0) {
                // CountUpText self-animates (counts up from 0 on appear, re-rolls on value change),
                // so the score is passed straight through — no external roll state needed.
                CountUpText(
                    value: score,
                    format: { StressTrace.formatLevel($0) },
                    font: StrandFont.rounded(34, weight: .bold),
                    color: .white
                )
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                Text("of 3")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .allowsHitTesting(false)   // taps fall through to the vessel → splash
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Stress \(StressTrace.formatLevel(score)) of 3"))
    }
}

// MARK: - Stress band

enum StressBand {
    case low, medium, high

    init(score: Double) {
        switch score {
        case ..<1.0: self = .low
        case ..<2.0: self = .medium
        default:     self = .high
        }
    }

    var title: String {
        switch self {
        case .low:    return String(localized: "LOW")
        case .medium: return String(localized: "MEDIUM")
        case .high:   return String(localized: "HIGH")
        }
    }

    var tone: StrandTone {
        switch self {
        case .low:    return .positive
        case .medium: return .warning
        case .high:   return .critical
        }
    }
}

// MARK: - Stress ramp (the WHOOP Stress sweep: blue → green → amber)
//
// The Stress screen's one ramp. WHOOP has NO gold: calm reads as the link blue, a
// balanced day as positive green, and a high-stress day as warning amber. The
// semicircle gauge fill, the day autonomic-load line, the Calm/Moderate/High totals bar
// and the trend all sample this SAME ramp, so the colour language is identical across
// the screen. Never the gold or red→green recovery ramp.

enum StressRamp {
    /// Band anchors, lifted from the shared palette (no hard-coded hex). These are the
    /// blue / green / amber the totals legend and band dots use, kept in lock-step with
    /// the gauge gradient below.
    static let calm    = StrandPalette.accent         // #60A0E0 — calm WHOOP blue
    static let steady  = StrandPalette.statusPositive // #03E095 — balanced WHOOP green
    static let tense   = StrandPalette.statusWarning  // #F0A020 — high WHOOP amber

    /// The 3-stop gauge ramp, evenly spaced (blue → green → amber).
    static let stops: [Gradient.Stop] = [
        .init(color: calm,   location: 0.00),
        .init(color: steady, location: 0.50),
        .init(color: tense,  location: 1.00),
    ]

    /// The blue→green→amber gauge gradient, built from the WHOOP band anchors above.
    static let gradient = Gradient(stops: stops)

    /// Sample the ramp at a 0–3 stress score.
    static func color(_ score: Double) -> Color {
        StrandPalette.sample(stops: stops, at: min(max(score / 3.0, 0), 1))
    }
}

// MARK: - Stress model inputs (cache key)

/// An `Equatable` snapshot of everything `StressModel.init` reads, used to decide
/// when the cached model must be rebuilt. `DailyMetric` is already `Equatable`;
/// the stored series is a tuple array (not `Equatable`), so we mirror it into an
/// `Equatable` shape. Comparison is O(n) — cheap versus rebuilding the model.
private struct StressInputs: Equatable {
    let days: [DailyMetric]
    let stored: [StoredPoint]

    struct StoredPoint: Equatable {
        let day: String
        let value: Double
    }

    init(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        self.days = days
        self.stored = stored.map { StoredPoint(day: $0.day, value: $0.value) }
    }
}

// MARK: - Stress model (transparent: stored value OR z-score derivation)

struct StressModel {
    let score: Double            // 0–3 (today)
    let band: StressBand
    let explanation: String
    let rhrToday: Int?
    let hrvToday: Double?
    let rhrDelta: Double?        // today − baseline mean (bpm)
    let hrvDelta: Double?        // today − baseline mean (ms)
    let fullTrend: [TrendPoint]  // entire daily proxy history, oldest→newest
    let calmTimeValue: String    // e.g. "58%"
    let calmTimeCaption: String  // e.g. "of last 30 days"
    let usingStored: Bool        // true when today's value came from the stored series

    /// Last up-to-14 trend values, for the hero tile sparkline.
    var sparkValues: [Double] { Array(fullTrend.suffix(14)).map(\.value) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Build from oldest→newest daily metrics plus any stored "stress" series.
    /// Returns nil only when there is no usable signal at all.
    init?(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        // Stored values keyed by day, clamped to 0–3.
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) },
            uniquingKeysWith: { _, b in b }
        )

        // Carry (#543): today's own row is often vitals-less until the overnight is analyzed —
        // especially right after an app update relaunches and re-runs the pass — so score the NEWEST
        // day that actually carries usable signal (RHR/HRV, or a stored/imported stress value) instead of
        // calibrating, the same last-night carry every other Today vital uses. The predicate mirrors the
        // storedToday||derived gate below, so an imported stress-only latest day is still honored (not
        // skipped). Falls back to the last row when no day has any signal (cold start).
        guard let idx = days.lastIndex(where: {
            $0.restingHr != nil || $0.avgHrv != nil || storedByDay[$0.day] != nil
        }) ?? days.indices.last
        else { return nil }   // no days at all
        let today = days[idx]

        // Baseline window: up to 30 days ending the day BEFORE the scored day, so it's measured
        // against its own recent past rather than itself.
        let baseline = idx > 0 ? Array(days[0..<idx].suffix(30)) : []

        let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = baseline.compactMap { $0.avgHrv }

        let meanRHR = StressMath.mean(rhrBase)
        let sdRHR   = StressMath.std(rhrBase, mean: meanRHR)
        let meanHRV = StressMath.mean(hrvBase)
        let sdHRV   = StressMath.std(hrvBase, mean: meanHRV)

        let rhrT = today.restingHr.map(Double.init)
        let hrvT = today.avgHrv

        // Resolve today's score: prefer a stored value, else derive.
        let derivedAvailable = (rhrT != nil && meanRHR != nil) || (hrvT != nil && meanHRV != nil)
        let storedToday = storedByDay[today.day]
        guard storedToday != nil || derivedAvailable else { return nil }

        let derivedToday: Double? = derivedAvailable
            ? StressMath.squash(StressMath.rawScore(
                rhrToday: rhrT, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: hrvT, meanHRV: meanHRV, sdHRV: sdHRV))
            : nil

        let s = storedToday ?? derivedToday ?? 1.5
        self.usingStored = storedToday != nil
        self.score = s
        self.band = StressBand(score: s)
        self.rhrToday = today.restingHr
        self.hrvToday = hrvT
        self.rhrDelta = (rhrT != nil && meanRHR != nil) ? (rhrT! - meanRHR!) : nil
        self.hrvDelta = (hrvT != nil && meanHRV != nil) ? (hrvT! - meanHRV!) : nil

        self.explanation = StressMath.explanation(
            band: self.band,
            rhrDelta: self.rhrDelta,
            hrvDelta: self.hrvDelta,
            usingStored: self.usingStored
        )

        // Full daily proxy history: stored value if present for the day, else the
        // z-score derivation against the SAME baseline so the line is comparable.
        var pts: [TrendPoint] = []
        for d in days {
            guard let date = Self.dayParser.date(from: d.day) else { continue }
            if let v = storedByDay[d.day] {
                pts.append(TrendPoint(date: date, value: v))
                continue
            }
            let dRHR = d.restingHr.map(Double.init)
            let dHRV = d.avgHrv
            guard (dRHR != nil && meanRHR != nil) || (dHRV != nil && meanHRV != nil) else { continue }
            let r = StressMath.rawScore(
                rhrToday: dRHR, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: dHRV, meanHRV: meanHRV, sdHRV: sdHRV
            )
            pts.append(TrendPoint(date: date, value: StressMath.squash(r)))
        }
        self.fullTrend = pts

        // "Calm time": share of the last 30 charted days that sat in the LOW band.
        let recent = Array(pts.suffix(30))
        if recent.isEmpty {
            self.calmTimeValue = "—"
            self.calmTimeCaption = String(localized: "needs history")
        } else {
            let calm = recent.filter { $0.value < 1.0 }.count
            let pct = Int((Double(calm) / Double(recent.count) * 100).rounded())
            self.calmTimeValue = "\(pct)%"
            self.calmTimeCaption = String(localized: "low-stress days · \(recent.count)d")
        }
    }

    /// One arbitrary day's sleep-vitals stress detail — the "Sommeil" card's content when paging to
    /// a day other than the hero's own (`init?` above only ever resolves the LATEST signal-bearing
    /// day). Same baseline window (up to 30 days ending the day before), same `StressMath` calls;
    /// kept as its own standalone lookup rather than refactoring `init?` to share it, so the hero's
    /// already-shipped path is untouched by this addition.
    struct DayDetail {
        let score: Double
        let band: StressBand
        let rhrDelta: Double?
        let hrvDelta: Double?
        let explanation: String
        let usingStored: Bool
    }

    static func detail(forDayKey dayKey: String, days: [DailyMetric],
                       stored: [(day: String, value: Double)]) -> DayDetail? {
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) }, uniquingKeysWith: { _, b in b }
        )
        guard let idx = days.firstIndex(where: { $0.day == dayKey }) else { return nil }
        let day = days[idx]
        let baseline = idx > 0 ? Array(days[0..<idx].suffix(30)) : []
        let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = baseline.compactMap { $0.avgHrv }
        let meanRHR = StressMath.mean(rhrBase), sdRHR = StressMath.std(rhrBase, mean: StressMath.mean(rhrBase))
        let meanHRV = StressMath.mean(hrvBase), sdHRV = StressMath.std(hrvBase, mean: StressMath.mean(hrvBase))
        let rhrT = day.restingHr.map(Double.init)
        let hrvT = day.avgHrv

        let derivedAvailable = (rhrT != nil && meanRHR != nil) || (hrvT != nil && meanHRV != nil)
        let storedDay = storedByDay[day.day]
        guard storedDay != nil || derivedAvailable else { return nil }
        let derived: Double? = derivedAvailable
            ? StressMath.squash(StressMath.rawScore(
                rhrToday: rhrT, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: hrvT, meanHRV: meanHRV, sdHRV: sdHRV))
            : nil
        let s = storedDay ?? derived ?? 1.5
        let band = StressBand(score: s)
        let rhrDelta = (rhrT != nil && meanRHR != nil) ? (rhrT! - meanRHR!) : nil
        let hrvDelta = (hrvT != nil && meanHRV != nil) ? (hrvT! - meanHRV!) : nil
        return DayDetail(
            score: s, band: band, rhrDelta: rhrDelta, hrvDelta: hrvDelta,
            explanation: StressMath.explanation(band: band, rhrDelta: rhrDelta, hrvDelta: hrvDelta,
                                                usingStored: storedDay != nil),
            usingStored: storedDay != nil
        )
    }
}

// MARK: - Stress math (pure, testable helpers)

enum StressMath {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. RHR-up and HRV-down both push it positive.
    static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR            // up = stress
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV            // down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5).
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    static func explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?, usingStored: Bool) -> String {
        let rhrUp = (rhrDelta ?? 0) > 1.0
        let rhrDn = (rhrDelta ?? 0) < -1.0
        let hrvUp = (hrvDelta ?? 0) > 1.0
        let hrvDn = (hrvDelta ?? 0) < -1.0

        switch band {
        case .high:
            if rhrUp && hrvDn {
                return String(localized: "Resting HR is elevated and HRV is below your baseline, both classic signs of high activation. Prioritise rest, hydration and an easy day.")
            } else if hrvDn {
                return String(localized: "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover.")
            } else if rhrUp {
                return String(localized: "Resting heart rate is running high versus your norm. Your body is under load today. Keep effort light.")
            }
            return String(localized: "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day.")
        case .medium:
            if rhrUp || hrvDn {
                return rhrUp
                    ? String(localized: "Slightly off baseline (resting HR is a touch high), so you're moderately activated. Nothing alarming; just don't overreach.")
                    : String(localized: "Slightly off baseline (HRV is a little low), so you're moderately activated. Nothing alarming; just don't overreach.")
            }
            return String(localized: "You're sitting around your typical autonomic baseline: moderate stress, a normal, balanced day.")
        case .low:
            if rhrDn && hrvUp {
                return String(localized: "Resting heart rate is low and HRV is up. Your nervous system looks well-recovered and calm. A great day to push if you want to.")
            } else if hrvUp {
                return String(localized: "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low.")
            }
            return String(localized: "Resting heart rate and HRV are sitting at or below baseline: low physiological stress. You're in a calm, recovered state.")
        }
    }
}

// MARK: - Daytime autonomic-load line (README screen-9)
//
// The day's intraday stress proxy drawn as a smooth LINE across the waking hours, filled
// under the curve and stroked with the SAME 3-stop blue→green→amber WHOOP ramp as
// the gauge. Only scored hours contribute points (no-data hours are skipped, never a
// guessed value); the smooth line connects the ones we have. The y-axis is the 0–3 scale
// and a faint dashed mid-line marks the 1.5 baseline.

struct DaytimeLoadLine: View {
    let hours: [DaytimeStress.HourPoint]
    /// When set, positions points by actual time-of-day across a full 24h axis (`dayStart` to
    /// `dayStart` + 24h) instead of evenly across the array index — the only way a sleep span and
    /// workout markers can share one coordinate system with the line (#WHOOP-parity). nil (the
    /// default) keeps the original index-packed layout every existing caller (Today, the widget)
    /// already relies on, byte-identical, since neither wants the night drawn at all.
    var dayStart: Date? = nil
    /// Shaded band + moon glyph for the night, in the SAME `dayStart`-relative coordinate system.
    /// Ignored when `dayStart` is nil.
    var sleepSpan: (start: Date, end: Date)? = nil
    /// Small tick marks for logged workouts overlapping the day, positioned the same way. Ignored
    /// when `dayStart` is nil.
    var activityMarkers: [(start: Date, end: Date)] = []

    private let chartHeight: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // y maps a 0–3 level into the chart (0 at bottom), for the baseline rule below. The x
            // placement moved into `scoredRuns`, which needs it per point anyway.
            // (a closure, not a `func` — a `@ViewBuilder` closure can't contain declarations)
            let y: (Double) -> CGFloat = { level in h - h * CGFloat(min(max(level / 3.0, 0), 1)) }

            // Contiguous runs of scored hours. Built in a method, not here: this is a
            // `@ViewBuilder` closure and cannot hold statements.
            let runs = scoredRuns(width: w, height: h)

            ZStack {
                if let dayStart {
                    if let sleepSpan {
                        sleepShading(sleepSpan, dayStart: dayStart, width: w, height: h)
                    }
                    ForEach(Array(activityMarkers.enumerated()), id: \.offset) { _, span in
                        activityMarker(span, dayStart: dayStart, width: w, height: h)
                    }
                }
                // Baseline (1.5 of 3) reference line.
                Path { p in
                    let yb = y(1.5)
                    p.move(to: CGPoint(x: 0, y: yb))
                    p.addLine(to: CGPoint(x: w, y: yb))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // The ramp runs DOWN the chart, not across the day.
                //
                // It used to be `.leading` to `.trailing`, which painted the stress band colours along
                // the x-axis: a calm 9pm hour rendered amber and a tense 7am one blue, so the colour
                // said nothing about the score while looking exactly as though it did. Because y maps
                // the 0-3 level onto the chart, a vertical ramp makes vertical position the level, which
                // is what the Kotlin twin does and what the legend claims. Amber at the top, blue at the
                // bottom: `StressRamp.gradient` runs calm-first, so it is reversed here.
                let levelRamp = LinearGradient(
                    gradient: Gradient(colors: Array(StressRamp.stops.map(\.color).reversed())),
                    startPoint: .top, endPoint: .bottom
                )
                ForEach(Array(runs.enumerated()), id: \.offset) { _, seg in
                    if seg.count >= 2 {
                        // Closed PER RUN, so the wash cannot spread under an hour that was never scored
                        // and undo the gap the broken line just drew.
                        areaPath(seg, width: w, height: h)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        StressRamp.calm.opacity(0.22),
                                        StressRamp.calm.opacity(0.02),
                                    ]),
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        linePath(seg)
                            .stroke(levelRamp,
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    } else if let only = seg.first {
                        // A run of one scored hour: a dot rather than a line. Coloured by the level it
                        // actually carries — it used to be hardcoded to the mid colour, so a lone HIGH
                        // hour drew as an ordinary one.
                        Circle()
                            .fill(StressRamp.color(level(at: only.1, height: h)))
                            .frame(width: 6, height: 6)
                            .position(x: only.0, y: only.1)
                    }
                }
            }
        }
        .frame(height: chartHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// CONTIGUOUS RUNS of scored hours, in chart coordinates.
    ///
    /// The old path `compactMap`-ed the unscored hours away and stroked a smooth curve through whatever
    /// was left, which draws a reading straight across an hour that has none — the one thing the caption
    /// promises it will not do. Splitting into runs lets each be stroked and filled separately, so a
    /// hole in the day stays a hole. The Kotlin twin has always broken the line here.
    ///
    /// Two x-placements: `dayStart` set positions each point by its ACTUAL time-of-day fraction across
    /// 24h (`timeFraction`), so the waking line sits in the middle of the axis with real empty space on
    /// either side for the night, and a sleep span / activity marker drawn in the same system lines up
    /// with it. `dayStart` nil keeps the original by-index spacing (every pre-existing caller).
    private func scoredRuns(width w: CGFloat, height h: CGFloat) -> [[(CGFloat, CGFloat)]] {
        let n = max(hours.count, 1)
        var out: [[(CGFloat, CGFloat)]] = []
        var run: [(CGFloat, CGFloat)] = []
        for (i, p) in hours.enumerated() {
            guard let level = p.level else {
                if !run.isEmpty { out.append(run); run = [] }
                continue
            }
            let px: CGFloat
            if let dayStart {
                px = w * timeFraction(Date(timeIntervalSince1970: Double(p.startTs)), dayStart: dayStart)
            } else {
                px = n <= 1 ? w / 2 : w * CGFloat(i) / CGFloat(n - 1)
            }
            let py = h - h * CGFloat(min(max(level / 3.0, 0), 1))
            run.append((px, py))
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    /// `date`'s position within [dayStart, dayStart + 24h), clamped to 0...1.
    private func timeFraction(_ date: Date, dayStart: Date) -> CGFloat {
        let span = date.timeIntervalSince(dayStart) / 86_400
        return CGFloat(min(max(span, 0), 1))
    }

    @ViewBuilder
    private func sleepShading(_ span: (start: Date, end: Date), dayStart: Date,
                              width w: CGFloat, height h: CGFloat) -> some View {
        let x0 = w * timeFraction(span.start, dayStart: dayStart)
        let x1 = w * timeFraction(span.end, dayStart: dayStart)
        if x1 > x0 {
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(StrandPalette.hairline.opacity(0.35))
                    .frame(width: x1 - x0, height: h)
                    .position(x: (x0 + x1) / 2, y: h / 2)
                Image(systemName: "moon.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .position(x: x0 + 10, y: 10)
            }
        }
    }

    private func activityMarker(_ span: (start: Date, end: Date), dayStart: Date,
                                width w: CGFloat, height h: CGFloat) -> some View {
        let x0 = w * timeFraction(span.start, dayStart: dayStart)
        let x1 = max(x0 + 2, w * timeFraction(span.end, dayStart: dayStart))
        return Rectangle()
            .fill(StrandPalette.accent.opacity(0.28))
            .frame(width: max(2, x1 - x0), height: 3)
            .position(x: (x0 + x1) / 2, y: 3)
    }

    /// The 0-3 level a chart y-position represents: the inverse of the `y` mapping above, so a lone
    /// point can be coloured by what it actually reads rather than by a fixed guess.
    private func level(at yPos: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double((height - yPos) / height) * 3.0
    }

    /// A smooth (Catmull-Rom-ish) stroke through the scored points.
    private func linePath(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let midX = (prev.0 + cur.0) / 2
            path.addCurve(
                to: CGPoint(x: cur.0, y: cur.1),
                control1: CGPoint(x: midX, y: prev.1),
                control2: CGPoint(x: midX, y: cur.1)
            )
        }
        return path
    }

    private func areaPath(_ pts: [(CGFloat, CGFloat)], width: CGFloat, height: CGFloat) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    private var accessibilitySummary: String {
        let scored = hours.compactMap { p in p.level.map { (p.hour, $0) } }
        guard !scored.isEmpty else { return String(localized: "No intraday stress data yet today.") }
        let parts = scored.map { "\($0.0):00 \(StressTrace.formatLevel($0.1))" }
        return String(localized: "Autonomic load today: \(parts.joined(separator: ", "))")
    }
}

// MARK: - Stress totals (Calm / Moderate / High) split for the day

/// Splits the day's SCORED waking hours into the three stress bands and exposes each
/// band's share + duration. Each intraday bucket is one hour (`DaytimeStress.bucketSeconds`),
/// so the band's hour-count is its duration. Calm = 0–1, Moderate = 1–2, High = 2–3.
struct StressTotals {
    let calmHours: Int
    let moderateHours: Int
    let highHours: Int

    init(hours: [DaytimeStress.HourPoint]) {
        var c = 0, m = 0, hi = 0
        for p in hours {
            guard let lvl = p.level else { continue }
            switch StressBand(score: lvl) {
            case .low:    c += 1
            case .medium: m += 1
            case .high:   hi += 1
            }
        }
        calmHours = c; moderateHours = m; highHours = hi
    }

    var total: Int { calmHours + moderateHours + highHours }

    /// 0...1 share of the scored day spent in each band (0 when no scored hours).
    func fraction(_ band: StressBand) -> Double {
        guard total > 0 else { return 0 }
        switch band {
        case .low:    return Double(calmHours) / Double(total)
        case .medium: return Double(moderateHours) / Double(total)
        case .high:   return Double(highHours) / Double(total)
        }
    }

    func hours(_ band: StressBand) -> Int {
        switch band {
        case .low:    return calmHours
        case .medium: return moderateHours
        case .high:   return highHours
        }
    }
}

// MARK: - Weekday baseline ("vs a typical <weekday>", #WHOOP-parity)

/// 0...1 band shares, comparable across days regardless of how many hours each one scored —
/// `StressTotals.fraction` already normalizes this way, this just gives the three a home that
/// isn't tied to one specific day's raw hour counts (needed to AVERAGE several days together).
struct BandSplit: Equatable {
    let low: Double
    let mid: Double
    let high: Double

    init(low: Double, mid: Double, high: Double) {
        self.low = low; self.mid = mid; self.high = high
    }

    init(totals: StressTotals) {
        self.low = totals.fraction(.low)
        self.mid = totals.fraction(.medium)
        self.high = totals.fraction(.high)
    }
}

/// `selectedDay` compared against its own last few same-weekday occurrences. See
/// `StressView.loadWeekdayBaseline`'s doc comment for how each half is built and why nothing here
/// is a new physiological score — both lenses reuse data the rest of the screen already computes.
struct WeekdayBaseline {
    let weekdayLabel: String
    /// Average of `StressModel.fullTrend`'s nightly 0–3 scores over the matched days.
    let sleepScoreAvg: Double?
    let sleepSampleDays: Int
    /// Average Calm/Moderate/High band shares over the matched days' own daytime timelines.
    let nonActivitySplit: BandSplit?
    let nonActivitySampleDays: Int
}

/// Two stacked proportional bars — `selectedDay`'s own Calm/Moderate/High split above a typical
/// same-weekday's — so the two are compared at a glance the way `WeekdayBaseline` computed them to
/// be. NOOP's own bar language (flat rounded segments, `StressRamp` colors), not WHOOP's pixel
/// style — the user asked to keep NOOP's look and only borrow WHOOP's content/structure here.
struct ComparisonBandBar: View {
    let today: BandSplit
    let typical: BandSplit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(today, label: String(localized: "Today"))
            row(typical, label: String(localized: "Typical"))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(
            localized: "Today: \(pct(today.low))% calm, \(pct(today.mid))% moderate, \(pct(today.high))% high. Typical: \(pct(typical.low))% calm, \(pct(typical.mid))% moderate, \(pct(typical.high))% high."
        ))
    }

    private func row(_ split: BandSplit, label: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 0) {
                    segment(StressRamp.calm, frac: split.low, width: w)
                    segment(StressRamp.steady, frac: split.mid, width: w)
                    segment(StressRamp.tense, frac: split.high, width: w)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 8)
        }
    }

    @ViewBuilder
    private func segment(_ color: Color, frac: Double, width: CGFloat) -> some View {
        let w = width * CGFloat(min(max(frac, 0), 1))
        if w > 0 { Rectangle().fill(color).frame(width: w) }
    }

    private func pct(_ frac: Double) -> Int { Int((frac * 100).rounded()) }
}

// MARK: - Stress totals bar (README screen-9, liquid finish)
//
// The Calm / Moderate / High split of the scored day, rendered as three labelled liquid tubes (the
// signature LiquidTube, matching Health's recovery contributors and Today's Key-Metrics tubes). Each
// tube fills to that band's SHARE of the scored day and is tinted to the band's WHOOP colour (calm blue /
// steady green / tense amber), with the band name + its duration above it. A day with no scored hours
// leaves all three tubes empty (no fabricated fill).

struct StressTotalsBar: View {
    let totals: StressTotals

    private struct Band: Identifiable {
        let id = UUID()
        let band: StressBand
        let label: String
        let color: Color
    }

    private var bands: [Band] {
        [
            Band(band: .low,    label: String(localized: "Calm"),     color: StressRamp.calm),
            Band(band: .medium, label: String(localized: "Moderate"), color: StressRamp.steady),
            Band(band: .high,   label: String(localized: "High"),     color: StressRamp.tense),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(bands) { b in
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(b.label)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(durationLabel(totals.hours(b.band)))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    // The signature liquid tube: fills to the band's share of the scored day, tinted to the
                    // band colour. Static (posed) — a row of small bars shouldn't each run a live Canvas.
                    LiquidTube(frac: totals.fraction(b.band), tint: b.color, height: 10, animated: false)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            String(localized: "Today's stress split: calm \(durationLabel(totals.calmHours)), moderate \(durationLabel(totals.moderateHours)), high \(durationLabel(totals.highHours)).")
        )
    }

    /// "—" when a band had no scored hours, else "Nh" (each scored bucket is one hour).
    private func durationLabel(_ hours: Int) -> String {
        hours <= 0 ? "—" : String(localized: "\(hours)h")
    }
}

// MARK: - Preview

#if DEBUG
private func sampleStressTrend(_ n: Int) -> [TrendPoint] {
    let cal = Calendar.current
    let today = Date()
    return (0..<n).map { i in
        let date = cal.date(byAdding: .day, value: -(n - 1 - i), to: today)!
        let v = 1.4 + 0.9 * sin(Double(i) / 2.4) + Double((i * 13) % 5) * 0.12
        return TrendPoint(date: date, value: min(max(v, 0), 3))
    }
}

/// A sample waking-hour timeline (06:00→22:00) for the preview, with a couple of
/// no-signal gaps so the line break reads honestly.
private func sampleDaytimeHours() -> [DaytimeStress.HourPoint] {
    let base = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
    return (DaytimeStress.wakingStartHour...DaytimeStress.wakingEndHour).map { h in
        let curve = 1.3 + 1.1 * sin(Double(h - 6) / 3.2)
        // Drop two hours to show the gap behaviour.
        let level: Double? = (h == 11 || h == 17) ? nil : min(max(curve, 0), 3)
        return DaytimeStress.HourPoint(hour: h, startTs: base + h * 3600,
                                       level: level, meanHR: 64, rmssd: 38)
    }
}

private struct StressPreviewHarness: View {
    let score: Double
    @State private var range: ExploreRange = .month
    var body: some View {
        let band = StressBand(score: score)
        let hours = sampleDaytimeHours()
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Stress").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)

                // Liquid hero — the stress-level vessel + band + one plain-English line.
                NoopCard(tint: StressRamp.calm) {
                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        HStack {
                            Text("Stress monitor").strandOverline()
                            Spacer()
                            StatePill("\(band.title)", tone: band.tone)
                        }
                        HStack(alignment: .center, spacing: NoopMetrics.space5) {
                            StressHeroGauge(score: score, tint: StressRamp.color(score))
                            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                Text(band.title).font(StrandFont.overline)
                                    .tracking(StrandFont.overlineTracking)
                                    .foregroundStyle(StressRamp.color(score))
                                Text(StressMath.explanation(band: band, rhrDelta: 3, hrvDelta: -8, usingStored: false))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                // Screen-9 day autonomic-load line + Calm/Moderate/High totals bar.
                NoopCard(tint: StressRamp.calm) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Autonomic load through the day").strandOverline()
                        DaytimeLoadLine(hours: hours)
                        Divider().overlay(StrandPalette.hairline)
                        StressTotalsBar(totals: StressTotals(hours: hours))
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: NoopMetrics.gap)],
                          alignment: .leading, spacing: NoopMetrics.gap) {
                    StatTile(label: "Stress", value: StressTrace.formatLevel(score),
                             caption: "of 3 · \(band.title)", accent: StressRamp.color(score))
                    StatTile(label: "Resting HR", value: "54 bpm", accent: StrandPalette.metricRose,
                             delta: "+3 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "HRV", value: "48 ms", accent: StrandPalette.metricPurple,
                             delta: "−8 vs base", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "Calm time", value: "58%", caption: "low-stress days · 30d",
                             accent: StressRamp.calm)
                }

                ChartCard(title: "Stress · M", subtitle: "Daily 0-3 proxy", trailing: "avg 1.5") {
                    TrendChart(points: sampleStressTrend(30), gradient: StressRamp.gradient,
                               valueRange: 0...3, showsArea: true, height: NoopMetrics.chartHeight,
                               valueFormat: { StressTrace.formatLevel($0) })
                } footer: {
                    ChartFooter([("Today", StressTrace.formatLevel(score)), ("Average", "1.5"), ("Days", "30")])
                }
                SegmentedPillControl(ExploreRange.allCases, selection: $range,
                                     adaptsToAvailableWidth: true) { $0.label }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Stress — HIGH") {
    StressPreviewHarness(score: 2.4)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}

#Preview("Stress — LOW") {
    StressPreviewHarness(score: 0.6)
        .frame(width: 720, height: 1000)
        .preferredColorScheme(.dark)
}
#endif
