import Foundation
import WhoopProtocol

// DaytimeStress.swift — an intraday (hour-by-hour) read of the SAME autonomic stress
// proxy the daily Stress monitor shows, computed from the day's banked HR + R-R.
//
// The daily Stress score (StressView / StressScreen) maps "resting HR up + HRV down vs
// a personal baseline" onto a 0–3 logistic. This helper applies that SAME math at the
// per-hour grain so the Stress screen can show *when* in the day stress ran high — not
// a new score. For each waking hour it computes:
//
//   • mean HR over the hour                    (HR up   = stress, like daily RHR)
//   • RMSSD over the hour's clean R-R          (HRV down = stress, like daily avgHRV)
//
// and z-scores each against the day's OWN quiet reference (the calm-hour median + the
// spread across hours), then squashes the z-sum onto 0–3 with the identical logistic
//   stress = 3 / (1 + e^(−raw)). 0 calm · 1.5 baseline · 3 high — same bands as the daily
// score. The day is its own baseline: a desk day with one tense afternoon reads that
// afternoon as elevated *relative to that person's own calm hours*, no cloud, no history
// needed beyond the day itself.
//
// "Sustained high stress" is an honest, conservative flag: the most recent `sustainedWindows`
// covered windows (36 x 5 min = 3 hours) must ALL sit in the HIGH band (≥ highBandFloor). It
// drives a passive in-app suggestion to run a Breathe session — never a notification.
//
// APPROXIMATE and non-clinical: an hour with too little data (few HR samples / too few
// clean beats) is reported as `.noData` and never invented.

public enum DaytimeStress {

    // MARK: - Tunables

    /// Minimum HR samples in a bucket before its mean HR is trusted. Rescaled for the 5-minute
    /// `bucketSeconds` (was 300, "~5 min at 1 Hz" over the OLD 1-hour bucket — ~8% coverage). Kept
    /// deliberately LOW rather than coverage-matched (8% of 5 min would be ~25) because a WHOOP 5/MG
    /// sends live HR only ~every 30 s (see `StrainScorer.minSparseReadings`'s own doc comment for the
    /// same hardware constraint) — a 25-sample floor would leave a 5/MG's daytime timeline blank
    /// almost everywhere. 5 clears a sparse 30 s-cadence device's ~10 real readings per 5-minute
    /// window comfortably while still rejecting a near-empty bucket.
    public static let minHourHRSamples: Int = 5
    /// Bucket width for the timeline, in seconds. FORK CHANGE (#WHOOP-parity, explicit request —
    /// "je veux toutes les 1 minute... comment on fait pour arriver à 1"): widened resolution from a
    /// full hour to 5 minutes, the shortest window RMSSD/HRV is scientifically meaningful over (the
    /// Task Force of the ESC's 1996 standard for "short-term" HRV) — a literal 1-minute SCORED window
    /// would make the HRV term statistical noise, not a tighter reading. `timelineStepSeconds` below
    /// is what actually delivers "updates every minute": the SCORED window stays a valid 5 minutes,
    /// it is just re-read every 60 s, the same relationship the old hour/half-hour pair had. Every
    /// "hour"-named type/variable in this file (`HourPoint`, `hourOfDay`, …) now means "one
    /// `bucketSeconds`-wide window", kept unrenamed to avoid a mechanical sweep through every reader
    /// of this file, the UI layer and the Kotlin twin for a label only — the WIDTH is what changed.
    public static let bucketSeconds: Int = 300
    /// How far apart each PHASE of the DISPLAY timeline sits — now 60 s (every minute), the explicit
    /// target. The scored unit stays a full `bucketSeconds` (5 min) window; this only decides how
    /// often that window is re-read. `analyzeUncached`'s `timeline` step walks every phase from this
    /// value up to (not including) `bucketSeconds` — with the current constants, 60/120/180/240 s —
    /// so a point lands on every minute, not just one straddling copy. Adjacent points share 4 of 5
    /// minutes of data (an 80% overlap) — expected and intended for a "live-updating" feel, the same
    /// relationship a moving average has to its own window width: each point is still a genuine
    /// 5-minute reading, just advanced one minute from its neighbour instead of restarting from
    /// scratch. FORK-ONLY, not ported to Android: the Kotlin twin keeps `bucketSeconds = 3600` /
    /// `timelineStepSeconds = 1800` (its own hourly/half-hour pair) — this is no longer its byte-twin.
    public static let timelineStepSeconds: Int = 60
    /// Band floor for "high" on the shared 0–3 scale (matches StressBand .high).
    public static let highBandFloor: Double = 2.0
    /// Consecutive most-recent covered 5-minute windows that must all be HIGH to flag sustained
    /// stress — 36 windows = 3 HOURS, unchanged from the original "3 consecutive hours" intent (was
    /// `sustainedHours = 3` when a window was an hour; renamed since "hours" would now be a false
    /// name for a count of 5-minute windows). Deliberately NOT rescaled down to "3 windows = 15
    /// minutes": the flag drives a passive Breathe-session suggestion, and 15 minutes of elevated
    /// readings is a normal brief spike, not the sustained pattern that nudge is for.
    public static let sustainedWindows: Int = 36
    /// First/last local hour-of-day treated as "waking" for the timeline. WIDENED TO THE FULL DAY
    /// (0–24, i.e. unbounded) at the user's explicit request to match WHOOP's own near-continuous
    /// chart: the window used to hard-cut at 22:00, which — as the code's own prior comment on
    /// `maskedForSleep` already flagged — excluded "a late bedtime past 22:00" purely by clock, not
    /// because the wearer was actually asleep, leaving a real gap in the drawn line between the
    /// cutoff and whenever sleep was actually detected. `overlapsSleep` is what actually carves out
    /// genuine sleep time (any hour, any clock position) for the separate sleep-window scoring — it
    /// does that job correctly regardless of this window's width, so widening this one only means a
    /// late-awake or early-awake stretch gets scored like any other waking hour instead of silently
    /// dropping out of the chart. Previously 06:00–22:00.
    public static let wakingStartHour: Int = 0
    public static let wakingEndHour: Int = 24

    // MARK: - Motion gate
    //
    // Cardiac signals alone cannot separate psychological stress from EXERTION: a brisk walk and a
    // tense meeting both raise HR and suppress HRV. FORK CHANGE, at the user's explicit request to
    // match WHOOP's own Stress monitor: this no longer withholds the score for an ambulatory hour.
    // Real exercise now reads as (correctly) elevated stress on the same continuous curve, rather than
    // leaving a gap — "you don't cut it, WHOOP keeps it running through my workouts." When the caller
    // supplies the day's gravity (wrist accelerometer), an hour that was substantially ambulatory is
    // still FLAGGED (`HourPoint.maskedForActivity == true`, for the UI to annotate) and still excluded
    // from the calm REFERENCE (so a workout's elevated HR cannot drag up what counts as "calm" for the
    // rest of the day) and from the coverage totals — but `level` is no longer nulled out for it.
    // No gravity → no flagging → byte-identical prior behaviour, so the gate only applies when motion
    // is actually observable. Orthogonal to `ScoringMode` below: this decides what counts toward the
    // calm reference, the mode decides WHERE that reference comes from.

    /// An hour whose gravity-derived activity clears `stressMotionThreshold` for at least this
    /// fraction of its records is EXERTION, not stress — flagged (`maskedForActivity`) and excluded
    /// from the calm reference, but still SCORED (see the MARK: Motion gate comment above). 0.30 means
    /// "at least 30 % of the hour was at or above that bar"; below it, a stray reach or one trip to the
    /// kitchen does not flag a desk hour. An hourly grain is coarse — this is the gate that later
    /// allows finer epochs, at which point the fraction can tighten. Range (0, 1].
    public static let activityMaskFraction: Double = 0.30
    /// FORK TUNING, not upstreamed: the per-record intensity bar the motion gate masks on.
    /// Deliberately set ABOVE `WorkoutDetector.motionThreshold` (0.20 L2-g, the codebase's calibrated
    /// WALK floor — desk ≈ 0.05–0.10 g, walking ≈ 0.2–0.4 g per that constant's own doc), not equal to
    /// it. At 0.20, ordinary brisk walking — which sits inside that same 0.2–0.4 g walking band —
    /// cleared the bar on nearly every record, so a 2-hour walk masked both hours outright instead of
    /// being read as (mildly elevated, still real) stress, the opposite of what a stress monitor
    /// should do with a day's ordinary movement. WHOOP's own Stress score keeps reading through
    /// ordinary daily activity and only stops at genuine exertion; this fork now does the same. 0.45
    /// sits just above the walking band's own documented 0.4 g ceiling, so brisk walking no longer
    /// trips the gate while sustained jogging/running-level motion still does. Separate constant from
    /// `WorkoutDetector.motionThreshold` on purpose — that one still gates workout AUTO-DETECTION
    /// and `SedentaryDetector` elsewhere, which is unrelated and must not move with this. Not
    /// independently validated against a ground-truth corpus (see the file's APPROXIMATE/non-clinical
    /// note); it is a reasoned extrapolation from this codebase's own documented walk-floor
    /// calibration, not a new physiological estimate.
    public static let stressMotionThreshold: Double = 0.45
    /// Post-exercise shadow: HR stays elevated for a while AFTER exertion ends, so a bucket that
    /// falls within `postActivityShadowWindowBuckets` of a directly-ambulatory bucket is ALSO masked
    /// WHILE its mean HR is still above the calm reference by this margin (bpm). A bucket whose HR has
    /// already returned to the calm reference is scored normally, so the shadow self-limits to genuine
    /// cardiac recovery — it does not chain indefinitely just because the window is wide. Range ≥ 0.
    public static let postActivityShadowBPM: Double = 8.0

    /// How many PRECEDING `bucketSeconds` buckets the post-exercise shadow looks back through for a
    /// directly-ambulatory one. FORK CHANGE: when a "bucket" was a full hour, looking back exactly ONE
    /// bucket already meant "the hour right after a workout" — a real ~1-hour post-exercise window.
    /// Now that `bucketSeconds` is 5 minutes (see that constant's doc), looking back only one bucket
    /// would mean just 5 minutes, far too short to represent genuine post-exercise HR elevation (which
    /// can run 30–60+ min for a hard effort) — so this widens the lookback to 12 buckets (12 x 5 min =
    /// 60 min) to preserve the ORIGINAL real-world duration the shadow was meant to cover, the same
    /// "keep the real-world meaning, rescale the count" treatment `sustainedWindows` got. Still
    /// self-limiting via `postActivityShadowBPM`'s own margin check — widening the lookback only means
    /// more buckets are ELIGIBLE to be shadowed, not that they automatically are.
    public static let postActivityShadowWindowBuckets: Int = 12

    /// The sigma an ACTIVITY-flagged (or post-activity shadow) hour's HR term divides by, bpm.
    /// Deliberately NOT `sdHR` (the spread ACROSS THE DAY'S OWN CALM HOURS, which is naturally tiny —
    /// a stable day might vary 2-3 bpm hour to hour): dividing an ordinary 20-30 bpm walking rise by
    /// that tiny spread produced a z-score that saturated `squash` to the 3.0 ceiling almost
    /// immediately, a real user report ("stress is always pegged to max the moment I'm just
    /// walking") directly contradicting the continuous-through-activity change's own intent (elevated
    /// but PROPORTIONAL to effort, the way WHOOP reads it). Raised THREE times now: first pass reused
    /// the validated `baselineRelativeHighMarginBPM` (15 bpm) — too steep. Second pass: 60 bpm. Third,
    /// at the explicit request to push the ceiling further out: 90 bpm. A fork judgement call, not
    /// re-validated against a reference, each pass further than the last: 90 bpm means even a brisk
    /// effort (40-50 bpm over calm) still reads moderate rather than maxed, and only a genuinely hard,
    /// sustained effort (well over 60-70 bpm above calm) approaches the 3.0 ceiling. Not upstreamed.
    public static let activityHRSigmaBPM: Double = 90.0

    /// VALIDATED (26-day Oura-reference correlation, HR-only): a personal daytime-HR elevation
    /// of ~15 bpm over a POOLED/ROLLING baseline — the 10th-percentile daytime HR pooled across
    /// days, ~65 bpm in the reference set — is where elevated HR starts reading as
    /// Oura-comparable "high" stress (r≈0.6 against Oura's own stress signal). A PER-DAY
    /// (day-relative) baseline scored WORSE in the same comparison (r 0.43–0.53): an all-day
    /// elevated day pulls its own floor up and masks the stress, which is exactly why
    /// `.baselineRelative` leans on `Baselines`' cross-day rolling EWMA instead of a day-local
    /// reference. TUNING SEAM: this is HR-only; HR+HRV (WHOOP-era, RMSSD included) is expected
    /// to beat this r≈0.6 ceiling — re-validate this margin once that comparison exists. See
    /// `marginToSigma` for how it's translated onto the shared 0–3 squash curve.
    public static let baselineRelativeHighMarginBPM: Double = 15.0

    /// Gate for whether the personal daytime-RMSSD baseline feeds the live 0–3 score. `false`:
    /// `.baselineRelative` scores HR-only, exactly the channel the r≈0.6 margin above was validated
    /// on. The RMSSD half of the pipeline — `dayDaytimeAggregate`, `foldDaytimeBaselines`, the
    /// `daytime_rmssd` config, and `rawScore`'s HRV term — is built and unit-tested, but stays OUT
    /// of the live score until it has its OWN Oura-reference validation pass.
    ///
    /// WHY OFF (validated against real WHOOP data, 2026-07): daytime RMSSD off the wrist is
    /// artifact-dominated — hourly values swing ~40→430 ms as posture / motion / talking break the
    /// R-R stream, an order of magnitude noisier than the overnight recumbent HRV the nightly
    /// baselines use. `rawScore` sums the HRV z EQUAL-WEIGHT with the HR z, so an artifact hour can
    /// swing the combined score by ±3 (the full band) on noise alone. Enabling it before it is shown
    /// to IMPROVE the correlation risks pushing the combined score BELOW the HR-only r≈0.6 ceiling —
    /// the exact regression `baselineRelativeHighMarginBPM`'s comment warns against. Flip to `true`
    /// only once daytime HR+RMSSD is validated to beat HR-only on an Oura-style stress reference.
    public static let daytimeRMSSDScoringEnabled: Bool = false

    // MARK: - Scoring mode

    /// WHERE each hour's "calm" reference point + spread come from. Every other step —
    /// bucketing, the waking-hour filter, the squash curve, sustained-high, high-stress-minutes
    /// — is identical between modes; only the reference differs.
    ///
    /// Relationship to the rest of the Stress screen (StressView.swift): the DAILY 0–3 score
    /// (`StressModel`) already compares last night's NIGHTLY resting-HR/HRV to a plain trailing
    /// 30-day mean/SD, computed locally in StressView (not via `Baselines`) — that's a
    /// once-a-day number from SLEEP vitals. The Advanced HRV card (`StressIndex`,
    /// `HRVFreqDomain`) is a today-only descriptive lens with no baseline at all. `.baselineRelative`
    /// is neither: it's an HOURLY breakdown of TODAY from DAYTIME/waking-hours HR+RMSSD against a
    /// PERSONAL cross-day rolling baseline. Daytime HR runs warmer than nocturnal resting HR
    /// (posture, thermic effect), so it needs its OWN baseline (`daytime_hr`/`daytime_rmssd`,
    /// below) rather than reusing the nightly `resting_hr`/`hrv` configs — reusing the nightly
    /// ones would systematically over-read stress. The three surfaces are complementary lenses
    /// on the same underlying autonomic signal, not competing implementations of one baseline.
    public enum ScoringMode: Equatable, Sendable {
        /// DEFAULT — unchanged from before this mode existed. Each hour is z-scored against
        /// THIS DAY's own calm-hour reference (`calmReference`): the lower quartile of the
        /// day's own waking-hour mean HR, the upper quartile of its own waking-hour RMSSD. No
        /// personal history needed — the day is its own baseline. Byte-identical output to the
        /// pre-existing single-mode `analyze` for the same hr/rr/tzOffsetSeconds.
        case dayRelative

        /// Oura-style — each hour is z-scored against the PERSONAL rolling baseline for daytime
        /// HR (and, when available, daytime RMSSD): the SAME Winsorized-EWMA machinery
        /// (`Baselines.update` / `Baselines.foldHistory`) that backs the nightly HRV /
        /// resting-HR baselines elsewhere in the app, using `Baselines.metricCfg["daytime_hr"]`
        /// / `["daytime_rmssd"]` (see `Baselines.daytimeHRCfg` / `daytimeRMSSDCfg`). A caller
        /// builds `hr` (and, when it has the history, `rmssd`) by folding this person's past
        /// daytime aggregates — VALIDATED as each day's 10th-percentile daytime HR (a pooled
        /// "how low does my HR run when I'm calm and awake" floor), the same way the nightly
        /// baselines are folded from past nights.
        ///
        /// The HR reference point is `hr.baseline`, but the HIGH-band threshold does NOT scale
        /// with this person's own day-to-day `hr.spread` — see `baselineRelativeHighMarginBPM`:
        /// the validated model is a roughly FIXED bpm margin over the personal floor, not a
        /// variability-scaled one. `hr.spread` still rides along on the passed-in state for
        /// other consumers; this mode simply doesn't read it for the HR term.
        ///
        /// `rmssd` is `nil` when no personal RMSSD baseline exists yet — e.g. an imported,
        /// Oura-era day with no R-R stream, so there is no history to fold one from. The
        /// stressor then honestly falls back to HR-only scoring for the whole read and flags
        /// `Result.hrOnlyFallback`; this mirrors the per-hour graceful-nil already in
        /// `rawScore`, just at the whole-baseline grain instead of the single-hour grain. The
        /// RMSSD term (when present) DOES still scale by `rmssd.spread` via `Baselines.sigma` —
        /// only the HR term has a validated fixed-margin figure so far.
        case baselineRelative(hr: BaselineState, rmssd: BaselineState?)
    }

    // MARK: - Output

    /// One hour of the daytime timeline. `level` is the shared 0–3 stress proxy, or nil
    /// when the hour had too little signal to score honestly.
    public struct HourPoint: Equatable, Sendable {
        /// Hour-of-day on the LOCAL clock (0–23), the bucket this point covers.
        public let hour: Int
        /// Unix seconds at the start of the bucket (wall-clock).
        public let startTs: Int
        /// Shared 0–3 stress proxy for the hour, or nil when `.noData`.
        public let level: Double?
        /// Mean HR over the hour (bpm), or nil.
        public let meanHR: Double?
        /// RMSSD over the hour's clean R-R (ms), or nil (too few clean beats).
        public let rmssd: Double?
        /// True when this hour was AMBULATORY (exertion). It is still SCORED (`level` is populated,
        /// see the MARK: Motion gate comment above) — this flag exists so the UI can annotate "this
        /// reading includes real activity, may run high from exertion" and so active hours are kept
        /// out of the calm reference and the coverage totals, not to hide the number. See the
        /// motion-gate constants above.
        public let maskedForActivity: Bool
        /// True when this hour was left unscored because it OVERLAPS the caller-supplied sleep
        /// span(s) — i.e. still genuinely asleep. `isWakingHour`'s own window now spans the full day
        /// (see that constant's doc comment), so this is the ONE thing that actually carves sleep out
        /// of the timeline, at any clock hour — a sleep-in past 6am or a late bedtime are both caught
        /// here by the real sleep span, not by a clock cutoff. Sleep HR/HRV — including the normal
        /// cortisol-driven rise right at waking — is not what this proxy is built to read as "stress",
        /// so it is excluded the same way an ambulatory hour is, not scored and misread as a tense
        /// morning. 0 sleep spans supplied → never true (byte-identical to every caller that does not
        /// know about sleep boundaries).
        public let maskedForSleep: Bool

        /// True when the hour was scored (had enough HR to place on the curve).
        public var hasData: Bool { level != nil }

        public init(hour: Int, startTs: Int, level: Double?, meanHR: Double?, rmssd: Double?,
                    maskedForActivity: Bool = false, maskedForSleep: Bool = false) {
            self.hour = hour
            self.startTs = startTs
            self.level = level
            self.meanHR = meanHR
            self.rmssd = rmssd
            self.maskedForActivity = maskedForActivity
            self.maskedForSleep = maskedForSleep
        }
    }

    /// The full daytime read: the hourly timeline plus the sustained-high summary.
    public struct Result: Equatable, Sendable {
        /// Waking-hour timeline, earliest → latest. Hours with no signal carry `level == nil`.
        public let hours: [HourPoint]
        /// True when the most recent `sustainedWindows` SCORED windows all sit in the HIGH band.
        public let sustainedHigh: Bool
        /// Count of trailing high hours backing `sustainedHigh` (0 when not sustained).
        public let sustainedRun: Int
        /// Mean stress across the SCORED hours, or nil when none were scorable.
        public let dayMean: Double?
        /// Peak scored hour (highest `level`), or nil.
        public let peak: HourPoint?
        /// Count of waking hours that were AMBULATORY (the motion gate fired), i.e.
        /// `hours.filter { $0.maskedForActivity }.count`. These hours ARE scored — this is coverage
        /// metadata for the UI ("N hours include activity, may run high from exertion"), not a count
        /// of hidden readings. 0 when no gravity was supplied or nothing was flagged; 0 for `.empty`.
        public let activityMaskedHours: Int
        /// Count of waking hours left unscored because they overlap a caller-supplied sleep span —
        /// `hours.filter { $0.maskedForSleep }.count`. 0 when no sleep spans were supplied (every
        /// pre-existing caller) or nothing overlapped; 0 for `.empty`. See `HourPoint.maskedForSleep`.
        public let sleepMaskedHours: Int
        /// ADDITIVE — total minutes across SCORED waking hours at/above `highBandFloor`, the
        /// Oura-comparable "time in high stress" figure. Each scored hour is one `bucketSeconds`
        /// bucket, so this is `(# high-band scored hours) * bucketSeconds / 60`. Compare against
        /// Oura's `stress_high_s / 60` — NOOP's timeline is hourly-grain vs Oura's ~5-minute
        /// grain, so treat this as a coarse approximation, not a precise match. 0 for `.empty`
        /// and for any day with no scored hours.
        public let highStressMinutes: Int
        /// ADDITIVE — true when `.baselineRelative` mode was requested but had no personal RMSSD
        /// baseline to score against (e.g. an imported Oura-era day with no R-R history), so the
        /// whole read honestly fell back to HR-only scoring. Always false in `.dayRelative` mode
        /// (there, a missing RMSSD is already handled per-hour by `rawScore`, not flagged
        /// day-wide) and false for `.empty`.
        public let hrOnlyFallback: Bool

        /// DISPLAY-ONLY sliding read of the same day: `hours` plus a point every
        /// `timelineStepSeconds`, each still scored over a full `bucketSeconds` window against the
        /// SAME reference `hours` used. Defaults to `hours` so a caller that never asked for it, and
        /// every existing test, sees exactly what it saw before.
        ///
        /// Deliberately NOT the input to anything that counts hours. `sustainedHigh`,
        /// `highStressMinutes`, `dayMean` and `peak` all stay on the non-overlapping `hours`, because
        /// overlapping windows would count the same minute more than once.
        public let timeline: [HourPoint]

        public init(hours: [HourPoint], sustainedHigh: Bool, sustainedRun: Int,
                    dayMean: Double?, peak: HourPoint?, activityMaskedHours: Int = 0,
                    sleepMaskedHours: Int = 0,
                    highStressMinutes: Int = 0, hrOnlyFallback: Bool = false,
                    timeline: [HourPoint]? = nil) {
            self.hours = hours
            self.timeline = timeline ?? hours
            self.sustainedHigh = sustainedHigh
            self.sustainedRun = sustainedRun
            self.dayMean = dayMean
            self.peak = peak
            self.activityMaskedHours = activityMaskedHours
            self.sleepMaskedHours = sleepMaskedHours
            self.highStressMinutes = highStressMinutes
            self.hrOnlyFallback = hrOnlyFallback
        }

        /// The scored hours only (level non-nil), in time order.
        public var scored: [HourPoint] { hours.filter { $0.level != nil } }

        /// Empty read — used when the day had no usable intraday HR at all.
        public static let empty = Result(hours: [], sustainedHigh: false, sustainedRun: 0,
                                         dayMean: nil, peak: nil, activityMaskedHours: 0,
                                         sleepMaskedHours: 0,
                                         highStressMinutes: 0, hrOnlyFallback: false)
    }

    // MARK: - Shared stress math (identical formula to the daily StressModel)

    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread. (Matches StressMath.std.)
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Minimum clean R-R beats a `bucketSeconds`-wide window needs before its RMSSD is trusted.
    /// FORK ADDITION, surfaced by the bucket-width change: `HRVAnalyzer.analyze(rawRR:)` defaults to
    /// its own `minBeats` (20), a figure validated for a WHOLE NIGHT's worth of R-R — a 5-minute
    /// daytime bucket legitimately holds far fewer beats than a night does, so gating it at 20 read
    /// `.empty` for nearly every bucket regardless of how clean its beats were (caught by
    /// `DaytimeBaselinesTests.testDayRMSSDAggregateIsPresentWithRRAndTracksVariability` crashing on a
    /// nil RMSSD it used to get reliably). 8 matches this file's own `HRVAnalyzer.rollingRmssd`'s
    /// `minBeatsPerWindow` default, set there for exactly this "short window, not a night" reason.
    static let minDaytimeBucketRRBeats: Int = 8

    /// FORK ADDITION: how far a single HR sample may sit from its OWN bucket's median before
    /// `cleanedMeanHR` drops it as a sensor glitch (strap slip, motion artifact landing one bad
    /// reading among real ones), bpm.
    static let hrOutlierDeviationBPM: Double = 30.0

    /// Per-bucket mean HR with a single-pass outlier reject against the bucket's OWN median —
    /// mirrors `HRVAnalyzer`'s validated Malik-style approach (deviation from a local reference) but
    /// against the whole bucket's median rather than a sliding window: unlike RR intervals, bpm
    /// samples carry no meaningful beat-to-beat ORDER to center a local window on, so the bucket's own
    /// median IS the local reference. MOTIVATED by the bucket-width change in this file: an hourly
    /// bucket averaged 60+ HR samples, where one glitch barely moved the mean; a 5-minute bucket with
    /// a WHOOP 5/MG's sparse ~30 s cadence may carry as few as `minHourHRSamples` (5) — on that few
    /// samples, ONE bad reading can swing the mean by several bpm, exactly the kind of noise this
    /// file's z-score terms are sensitive to. Falls back to the plain mean when there are too few
    /// samples to trust a median (< 3) or when every sample would be rejected (never discards the
    /// whole reading over one disagreement) — this can only ever DROP samples toward what
    /// `minHourHRSamples`'s existing gate already requires, never invent one. Not independently
    /// validated against a ground-truth corpus; a reasoned extrapolation of the same cleaning
    /// principle already validated for RR, not a new physiological estimate.
    static func cleanedMeanHR(_ bpm: [Double]) -> Double? {
        guard !bpm.isEmpty else { return nil }
        guard bpm.count >= 3 else { return mean(bpm) }
        let med = quantile(bpm.sorted(), 0.5)
        let kept = bpm.filter { abs($0 - med) <= hrOutlierDeviationBPM }
        return mean(kept.isEmpty ? bpm : kept)
    }

    /// Combined autonomic z-score. HR-up and HRV-down both push it positive — the SAME
    /// directionality as the daily score (RHR up = stress, HRV down = stress).
    static func rawScore(hr: Double?, meanHR: Double?, sdHR: Double,
                         rmssd: Double?, meanRMSSD: Double?, sdRMSSD: Double) -> Double {
        var sum = 0.0
        if let h = hr, let m = meanHR, sdHR > 0.0001 {
            sum += (h - m) / sdHR              // HR up = stress
        }
        if let r = rmssd, let m = meanRMSSD, sdRMSSD > 0.0001 {
            sum += (m - r) / sdRMSSD           // HRV (RMSSD) down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5). Identical to
    /// StressMath.squash, so an hourly point shares the daily score's scale and bands.
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    /// Solve for the z-score spread `sd` such that a raw elevation of exactly `marginBPM` (or any
    /// unit — this is unit-agnostic) squashes to exactly `band` on the shared 0–3 curve:
    /// `band = 3 / (1 + e^(−marginBPM/sd))`. Used to translate `baselineRelativeHighMarginBPM`'s
    /// validated bpm figure into the `sd` the shared `squash` curve expects, so "baseline +
    /// margin" lands exactly on `band` by construction rather than by a second, separate
    /// threshold check. Defensive fallback (never divides by zero/negative-log) if `band` is
    /// ever configured at or outside the curve's open range (0, 3).
    static func marginToSigma(marginBPM: Double, atBand band: Double) -> Double {
        let ratio = 3.0 / band - 1.0
        guard ratio > 0, marginBPM > 0 else { return max(marginBPM, 1e-9) }
        return marginBPM / (-log(ratio))
    }

    /// The bucket a local timestamp falls in for a grid offset by `phase`.
    ///
    /// `phase = 0` is the on-the-hour grid every existing reading uses. `phase = timelineStepSeconds`
    /// is the same grid slid forward, so its windows straddle the hour boundaries rather than
    /// replacing them.
    private static func bucketOf(_ localTs: Int, phase: Int) -> Int {
        floorDiv(localTs - phase, bucketSeconds) * bucketSeconds + phase
    }

    // MARK: - Public API

    /// Build the daytime stress timeline from a day's banked HR + R-R.
    ///
    /// - Parameters:
    ///   - hr: the day's `[HRSample]` (any order; bucketed by ts here).
    ///   - rr: the day's `[RRInterval]`.
    ///   - gravity: the day's `[GravitySample]` (wrist accelerometer), for the motion gate. Defaults
    ///     empty: with no gravity NOTHING is flagged and the read is byte-identical to before. When
    ///     present, ambulatory hours are still SCORED (see the motion-gate constants and MARK comment
    ///     above — a fork change so real exercise reads as elevated stress instead of a gap) but are
    ///     flagged and excluded from the calm reference.
    ///   - sleepSpans: `(start, end)` unix-second ranges the caller knows were sleep (the primary
    ///     session, typically). Defaults empty: with none supplied, NOTHING is masked for sleep and
    ///     the read is byte-identical to before. When present, an hour overlapping any span is
    ///     excluded the same way an ambulatory hour is — see `HourPoint.maskedForSleep`'s doc
    ///     comment for why the 06:00 waking-window clock boundary alone is not enough (a sleep-in
    ///     morning routinely crosses it while still genuinely asleep).
    ///   - tzOffsetSeconds: seconds east of UTC, for placing each bucket on the LOCAL
    ///     clock (so "waking hours" and the hour labels are local). Defaults to UTC.
    ///   - mode: `.dayRelative` (DEFAULT — unchanged existing behaviour) or
    ///     `.baselineRelative` (Oura-style, vs a personal rolling baseline). ADDITIVE and
    ///     opt-in: existing callers that don't pass `mode` keep the exact prior behaviour.
    ///
    /// Returns `.empty` when there isn't a single hour with enough HR to score.
    ///   - includeTimeline: also compute `Result.timeline`, the sliding read is OPT-IN because half the callers do not want it.

    ///     The Stress screen reads `hours` and draws its own interactive timeline; making it pay for a
    ///     second pass of bucketing and one RMSSD per extra window, on the screen that already does three
    ///     200 000-row reads, would be cost for nothing. The widget and the Today card ask for it.
    public static func analyze(hr: [HRSample], rr: [RRInterval],
                               gravity: [GravitySample] = [],
                               sleepSpans: [(start: Int, end: Int)] = [],
                               tzOffsetSeconds: Int = 0,
                               mode: ScoringMode = .dayRelative,
                               includeTimeline: Bool = false) -> Result {
        // v7.0.2 perf (#707): buckets the day's full HR + R-R streams into per-hour aggregates and runs an
        // RMSSD per hour — invoked from the Stress view, so a `body` re-evaluation re-buckets the whole day.
        // Memoize on the streams' fingerprint + tz offset + scoring mode; result is a small `Result`, raw
        // arrays not held. The mode key folds in only (baseline, spread) for baseline-relative — the two
        // fields that can change the score — not the whole BaselineState (nValid/status/etc. never do).
        let modeKey: ModeKey
        switch mode {
        case .dayRelative:
            modeKey = .dayRelative
        case .baselineRelative(let hrBaseline, let rmssdBaseline):
            modeKey = .baselineRelative(hrBaseline: hrBaseline.baseline, hrSpread: hrBaseline.spread,
                                        rmssdBaseline: rmssdBaseline?.baseline, rmssdSpread: rmssdBaseline?.spread)
        }
        let key = StressKey(
            hr: StreamFingerprint.of(hr, ts: { $0.ts }, quant: { Int($0.bpm) }),
            rr: StreamFingerprint.of(rr, ts: { $0.ts }, quant: { Int($0.rrMs) }),
            // Fold all three axes into one quant so two different gravity streams cannot share a key
            // (same hr/rr with different motion must NOT reuse a cached result).
            gravity: StreamFingerprint.of(gravity, ts: { $0.ts }, quant: {
                Int(($0.x * 128).rounded()) &+ Int(($0.y * 128).rounded()) &* 257
                    &+ Int(($0.z * 128).rounded()) &* 66_049
            }),
            // The flag is part of the KEY, not just the call. Without it a screen read (false)
            // would seed the cache with a hourly-only result and the next widget read (true) would be
            // handed it, silently losing the sliding series with nothing to show why.
            // Tuples aren't Hashable, so `sleepSpans` folds into one Int the same way `gravity`
            // folds its three axes above — different spans must not collide onto the same key.
            sleepSpansFold: sleepSpans.reduce(0) { $0 &+ $1.start &* 131 &+ $1.end &* 257 },
            tz: tzOffsetSeconds, mode: modeKey, includeTimeline: includeTimeline)
        return analyzeCache.value(key) {
            analyzeUncached(hr: hr, rr: rr, gravity: gravity, sleepSpans: sleepSpans,
                            tzOffsetSeconds: tzOffsetSeconds,
                            mode: mode, includeTimeline: includeTimeline)
        }
    }

    private struct StressKey: Hashable {
        let hr: StreamFingerprint; let rr: StreamFingerprint; let gravity: StreamFingerprint
        let sleepSpansFold: Int
        let tz: Int; let mode: ModeKey; let includeTimeline: Bool
    }

    /// Hashable fingerprint of `ScoringMode` for the memo cache — `BaselineState` itself isn't
    /// `Hashable`, and only its `baseline`/`spread` can change the score, so those are what get
    /// folded in (see the `analyze` doc above).
    private enum ModeKey: Hashable {
        case dayRelative
        case baselineRelative(hrBaseline: Double, hrSpread: Double, rmssdBaseline: Double?, rmssdSpread: Double?)
    }

    private static let analyzeCache = AnalyticsMemoCache<StressKey, Result>(capacity: 8)

    private static func analyzeUncached(hr: [HRSample], rr: [RRInterval],
                                        gravity: [GravitySample],
                                        sleepSpans: [(start: Int, end: Int)],
                                        tzOffsetSeconds: Int, mode: ScoringMode,
                                        includeTimeline: Bool) -> Result {
        guard !hr.isEmpty else { return .empty }

        // Sleep gate (mirrors the motion gate below): a bucket whose [start, start+bucketSeconds)
        // wall-clock span overlaps ANY supplied sleep span by any amount is still genuinely asleep,
        // independent of `isWakingHour`'s own (now full-day) clock window. `bucket` here is the
        // LOCAL-shifted value every bucket key in this function is keyed by (`ts + tzOffsetSeconds`);
        // sleep spans arrive as raw wall-clock seconds, so the shift is undone before comparing —
        // same `bucket - tzOffsetSeconds` pattern `scoreGrid` already uses to recover wall-clock.
        func overlapsSleep(_ localShiftedBucket: Int) -> Bool {
            guard !sleepSpans.isEmpty else { return false }
            let wallStart = localShiftedBucket - tzOffsetSeconds
            let wallEnd = wallStart + bucketSeconds
            return sleepSpans.contains { wallStart < $0.end && wallEnd > $0.start }
        }

        // 1) Bucket HR + R-R into LOCAL hour-of-day buckets, keyed by the bucket start
        //    (floored to the hour on the local clock).
        func hrBuckets(_ phase: Int) -> [Int: [Double]] {
            var m: [Int: [Double]] = [:]
            for s in hr { m[bucketOf(s.ts + tzOffsetSeconds, phase: phase), default: []].append(Double(s.bpm)) }
            return m
        }
        func rrBuckets(_ phase: Int) -> [Int: [Double]] {
            var m: [Int: [Double]] = [:]
            for s in rr { m[bucketOf(s.ts + tzOffsetSeconds, phase: phase), default: []].append(Double(s.rrMs)) }
            return m
        }
        let hrByBucket = hrBuckets(0)
        let rrByBucket = rrBuckets(0)

        // 2) Per-hour mean HR + RMSSD (RMSSD via the shared HRV cleaner, so ectopic
        //    beats can't fabricate variability). An hour with < minHourHRSamples HR is
        //    left unscored (noData) — never invented.
        struct HourAgg { let bucket: Int; let meanHR: Double?; let rmssd: Double?; let nHR: Int }
        func aggregate(_ hrGrid: [Int: [Double]], _ rrGrid: [Int: [Double]]) -> [HourAgg] {
            let ordered = hrGrid.keys.sorted()
            var out: [HourAgg] = []
            out.reserveCapacity(ordered.count)
            for b in ordered {
                let hrs = hrGrid[b] ?? []
                let mHR = hrs.count >= minHourHRSamples ? cleanedMeanHR(hrs) : nil
                let rrRes = HRVAnalyzer.analyze(rawRR: rrGrid[b] ?? [], minBeats: minDaytimeBucketRRBeats)
                out.append(HourAgg(bucket: b, meanHR: mHR, rmssd: rrRes.rmssd, nHR: hrs.count))
            }
            return out
        }
        let aggs = aggregate(hrByBucket, rrByBucket)

        // 2b) Motion gate: bucket the day's gravity-derived activity by the SAME local hour and mark
        //     each hour AMBULATORY when at least `activityMaskFraction` of its records clear
        //     `stressMotionThreshold` — reusing the exact activity series `SedentaryDetector` /
        //     `WorkoutDetector` already trust, just scored against a higher, stress-specific bar (see
        //     that constant's doc for why it is not `WorkoutDetector.motionThreshold`). Empty gravity →
        //     no active buckets → nothing masked below (byte-identical to the pre-motion behaviour).
        // Derived ONCE and re-bucketed per grid. `activitySeries` walks the whole day's gravity, so
        // recomputing it for the second grid would have doubled the most expensive part of the motion
        // gate to answer the same question about the same samples.
        let activity = gravity.isEmpty ? [] : WorkoutDetector.activitySeries(gravity)
        func activeFractions(_ phase: Int) -> [Int: Double] {
            var out: [Int: Double] = [:]
            guard !activity.isEmpty else { return out }
            var counts: [Int: (active: Int, total: Int)] = [:]
            for p in activity {
                let bucket = bucketOf(p.ts + tzOffsetSeconds, phase: phase)
                var e = counts[bucket] ?? (0, 0)
                e.total += 1
                if p.intensity > stressMotionThreshold { e.active += 1 }
                counts[bucket] = e
            }
            for (b, e) in counts where e.total > 0 {
                out[b] = Double(e.active) / Double(e.total)
            }
            return out
        }
        let activeFracByBucket = activeFractions(0)
        func isAmbulatory(_ bucket: Int) -> Bool {
            (activeFracByBucket[bucket] ?? 0) >= activityMaskFraction
        }

        // 3) The reference point + spread for each signal — WHERE they come from depends on
        //    `mode`. Every other step (bucketing above incl. the motion gate, the waking-hour
        //    filter, the squash curve, sustained-high, high-stress-minutes below) is identical
        //    between modes; only the reference differs.
        let refHR: Double?
        let sdHR: Double
        let refRMSSD: Double?
        let sdRMSSD: Double
        let hrOnlyFallback: Bool
        switch mode {
        case .dayRelative:
            // The day's OWN quiet reference: centre on the CALM end (the lower quartile of
            // hourly mean HR, the upper quartile of hourly RMSSD), and spread from the
            // across-hour SD. This makes a flat day read ~baseline and a spiky day surface
            // its tense hours — without any cross-day history. Falls back to the plain mean
            // when there are too few scored hours for a quartile.
            //
            // Built from the WAKING hours only — the same hours scored in step 4. Sleep is the
            // calmest, lowest-HR / highest-HRV stretch of the day, and the analysis window
            // always begins at local midnight, so the current day routinely carries several
            // hours of it. Letting those night hours into the reference drags the "calm" anchor
            // far beneath every waking hour, inflating an ordinary calm day toward HIGH and
            // falsely tripping the sustained-high Breathe nudge.
            // Ambulatory hours are excluded from the day's OWN calm reference too (the motion
            // gate): an exertion hour's elevated HR / suppressed HRV must not pull the calm
            // anchor up or inflate the across-hour spread the z-scores divide by. Same reasoning
            // extends to the sleep gate: a sleep-in morning crossing 06:00 while still asleep must
            // not be read as the day's "calm baseline" either — that is sleep physiology, not an
            // achieved calm waking state, and folding it in would distort the very reference the
            // rest of the waking day gets compared against.
            let referenceAggs = aggs.filter {
                isWakingHour($0.bucket) && !isAmbulatory($0.bucket) && !overlapsSleep($0.bucket)
            }
            let hrMeans = referenceAggs.compactMap { $0.meanHR }
            let rmssdVals = referenceAggs.compactMap { $0.rmssd }
            refHR = calmReference(hrMeans, calmIsLow: true)         // calm HR is LOW
            refRMSSD = calmReference(rmssdVals, calmIsLow: false)   // calm HRV is HIGH
            sdHR = std(hrMeans, mean: mean(hrMeans))
            sdRMSSD = std(rmssdVals, mean: mean(rmssdVals))
            hrOnlyFallback = false

        case .baselineRelative(let hrBaseline, let rmssdBaseline):
            // The PERSONAL cross-day baseline, folded by the caller from past daytime
            // aggregates via `Baselines.update`/`foldHistory` (see the `ScoringMode` doc).
            // Ambulatory hours are still masked out of the SCORE in step 4 (the motion gate),
            // but the reference itself is external, so it needs no ambulatory exclusion here.
            refHR = hrBaseline.baseline
            // VALIDATED tuning, not `Baselines.sigma(hrBaseline)`: the correlation study behind
            // `baselineRelativeHighMarginBPM` found a roughly FIXED bpm margin over the personal
            // floor — not one scaled by this person's own day-to-day spread — best matched
            // Oura's stress signal. `marginToSigma` solves for the sd that makes exactly
            // `refHR + baselineRelativeHighMarginBPM` land on `highBandFloor` on the shared
            // squash curve, so the validated margin IS the "high" cutoff by construction.
            sdHR = Self.marginToSigma(marginBPM: baselineRelativeHighMarginBPM, atBand: highBandFloor)
            if let rmssdBaseline {
                refRMSSD = rmssdBaseline.baseline
                // No independently validated RMSSD margin yet (see the constant's doc) — this
                // term still scales by the person's own spread via the shared σ conversion.
                sdRMSSD = Baselines.sigma(rmssdBaseline)
                hrOnlyFallback = false
            } else {
                // No personal RMSSD baseline exists (e.g. an Oura-era day with no R-R history to
                // fold one from). `rawScore` already treats a nil meanRMSSD as "skip this term",
                // so passing nil here gracefully degrades to HR-only scoring — flagged honestly
                // in the output rather than silently.
                refRMSSD = nil
                sdRMSSD = 0
                hrOnlyFallback = true
            }
        }

        // 4) Score each waking-hour bucket on the shared 0–3 curve.
        //
        // Written against a supplied bucket grid so the SAME expression scores the on-the-hour pass
        // and the half-step display pass. One copy, so the two can never drift into scoring the same
        // hour differently — which is the whole reason the sliding read reuses the references
        // computed above rather than deriving its own.
        //
        func scoreGrid(_ gridAggs: [HourAgg], _ activeFrac: [Int: Double]) -> [HourPoint] {
            func ambulatory(_ bucket: Int) -> Bool {
                (activeFrac[bucket] ?? 0) >= activityMaskFraction
            }
            var points: [HourPoint] = []
            points.reserveCapacity(gridAggs.count)
            for a in gridAggs {
            guard isWakingHour(a.bucket) else { continue }
            let hourOfDayValue = hourOfDay(a.bucket)
            // The wall-clock bucket start (undo the local shift applied above).
            let wallStart = a.bucket - tzOffsetSeconds
            // Motion flag: an AMBULATORY hour — or the post-exercise shadow hour whose HR has not yet
            // recovered to the calm reference — is EXERTION. `maskedForActivity` still reports this
            // (the calm REFERENCE above still excludes these hours, and the UI still marks them), but
            // — at the user's explicit request, matching WHOOP's own Stress monitor — it no longer
            // withholds the score itself: real exercise reads as (correctly) high stress on the same
            // continuous curve rather than leaving a gap. The shadow is gated on `refHR` so it still
            // self-limits to genuine cardiac recovery for the FLAG, even though it no longer blocks
            // scoring. Only meaningful when the hour actually HAD a reading — a no-HR hour is plain
            // `.noData`, not "masked".
            let recentlyAmbulatory = (1...postActivityShadowWindowBuckets)
                .contains { ambulatory(a.bucket - $0 * bucketSeconds) }
            let shadow = recentlyAmbulatory
                && a.meanHR != nil && refHR != nil && a.meanHR! > refHR! + postActivityShadowBPM
            let masked = a.meanHR != nil && (ambulatory(a.bucket) || shadow)
            // Sleep gate: still genuinely asleep despite the clock crossing 06:00 (see
            // `overlapsSleep`'s doc comment). This ONE still withholds the score — sleep gets its own,
            // separately-scored reading via `analyzeSleepWindow`, merged in by the caller, so a nil
            // here is "read it from the sleep window instead", not "stress wasn't measured".
            let sleepMasked = a.meanHR != nil && overlapsSleep(a.bucket)
            // Score whenever HR cleared the count gate and the hour was not asleep (HR is the
            // always-available anchor; RMSSD enriches it). Activity no longer withholds the score
            // (see the MARK: Motion gate comment above) — but it DOES use `activityHRSigmaBPM`
            // instead of the day-local `sdHR` for the HR term (see that constant's own doc comment
            // for why). RMSSD is dropped for these hours (nil) rather than scaled: exertion
            // suppresses RMSSD by design, so including it here would double-count exertion as
            // "stress" from a second angle rather than correct the first.
            let level: Double? = (a.meanHR != nil && !sleepMasked)
                ? (masked
                    ? squash(rawScore(hr: a.meanHR, meanHR: refHR, sdHR: activityHRSigmaBPM,
                                      rmssd: nil, meanRMSSD: nil, sdRMSSD: 0))
                    : squash(rawScore(hr: a.meanHR, meanHR: refHR, sdHR: sdHR,
                                      rmssd: a.rmssd, meanRMSSD: refRMSSD, sdRMSSD: sdRMSSD)))
                : nil
            points.append(HourPoint(hour: hourOfDayValue, startTs: wallStart,
                                    level: level, meanHR: a.meanHR, rmssd: a.rmssd,
                                    maskedForActivity: masked, maskedForSleep: sleepMasked))
            }
            return points
        }
        let points = scoreGrid(aggs, activeFracByBucket)
        let activityMaskedHours = points.reduce(0) { $0 + ($1.maskedForActivity ? 1 : 0) }
        let sleepMaskedHours = points.reduce(0) { $0 + ($1.maskedForSleep ? 1 : 0) }

        // 4b) The sliding DISPLAY timeline: the same `bucketSeconds`-wide window re-read at EVERY
        //     `timelineStepSeconds` phase inside it (not just one straddling midpoint), scored against
        //     the SAME references, and merged with the on-the-grid points. FORK CHANGE: when
        //     `timelineStepSeconds` was exactly half of `bucketSeconds` (1800/3600), a single extra
        //     phase WAS the whole story — there is only one midpoint between two half-widths. Now that
        //     `timelineStepSeconds` (60) is a fifth of `bucketSeconds` (300), one extra phase would
        //     cover only 2 of the 5 one-minute slots in each bucket — a "1-minute display" that was
        //     still 5 minutes choppy most of the time. This loops every phase from
        //     `timelineStepSeconds` up to (not including) `bucketSeconds`, so with the current
        //     constants that is 60, 120, 180, 240 — four extra grids, landing a scored point on every
        //     minute, not just one offset copy. Every on-grid point survives untouched; only the
        //     straddling points are new, so the curve still passes through exactly the values scored
        //     above. Nothing that counts hours reads this — see `Result.timeline`.
        let timeline: [HourPoint] = {
            guard includeTimeline,
                  timelineStepSeconds > 0, timelineStepSeconds < bucketSeconds else { return points }
            var all = points
            var phase = timelineStepSeconds
            while phase < bucketSeconds {
                let midAggs = aggregate(hrBuckets(phase), rrBuckets(phase))
                all += scoreGrid(midAggs, activeFractions(phase))
                phase += timelineStepSeconds
            }
            return all.sorted { $0.startTs < $1.startTs }
        }()

        let scored = points.compactMap { p -> (HourPoint, Double)? in p.level.map { (p, $0) } }
        guard !scored.isEmpty else {
            // No scorable waking hour — still return the (unscored) timeline so the UI can
            // show "not enough data" rather than nothing. `hrOnlyFallback` is a MODE property
            // (whether a personal RMSSD baseline existed to score against), so it's still worth
            // reporting even though nothing ended up scored.
            return points.isEmpty ? .empty
                : Result(hours: points, sustainedHigh: false, sustainedRun: 0,
                         dayMean: nil, peak: nil, activityMaskedHours: activityMaskedHours,
                         sleepMaskedHours: sleepMaskedHours,
                         highStressMinutes: 0, hrOnlyFallback: hrOnlyFallback, timeline: timeline)
        }

        // 5) Sustained-high flag: walk back from the latest NON-ACTIVITY scored hour while each is
        //    HIGH, skipping over (not breaking on) activity-flagged hours — exertion is not the
        //    psychological stress this flag exists to catch, and the Breathe-session suggestion it
        //    drives should not fire purely because of a long workout. Before the fork change that made
        //    activity hours scored (see the Motion gate MARK above), those hours were simply absent
        //    from `scored`, so this reproduces that exact prior behaviour rather than a new one.
        let sustainedCandidates = scored.filter { !$0.0.maskedForActivity }
        var run = 0
        for (_, lvl) in sustainedCandidates.reversed() {
            if lvl >= highBandFloor { run += 1 } else { break }
        }
        let sustained = run >= sustainedWindows

        let dayMean = mean(scored.map { $0.1 })
        let peak = scored.max { $0.1 < $1.1 }?.0

        // 6) Oura-comparable "time in high stress": each scored hour at/above `highBandFloor`
        //    is one full `bucketSeconds` bucket, converted to minutes. Uses the SAME threshold
        //    `StressBand.high` (StressView) and the sustained-high check above already use, so
        //    all three stay in lockstep by construction.
        let highStressMinutes = scored.filter { $0.1 >= highBandFloor }.count * (bucketSeconds / 60)

        return Result(hours: points, sustainedHigh: sustained, sustainedRun: run,
                      dayMean: dayMean, peak: peak, activityMaskedHours: activityMaskedHours,
                      sleepMaskedHours: sleepMaskedHours,
                      highStressMinutes: highStressMinutes, hrOnlyFallback: hrOnlyFallback,
                      timeline: timeline)
    }

    // MARK: - Sleep-window read (continuous through the night, #WHOOP-parity)

    /// Continuous autonomic-activity read THROUGH one sleep span, using the SAME 0–3 formula as
    /// the waking proxy (`rawScore`/`squash`) but scored against the NIGHT'S OWN quartile-based
    /// calm reference (built from this span's own hours) rather than the day's waking one.
    ///
    /// Deliberately NOT a shared reference with `analyze`: the waking proxy's calm reference is
    /// built from AWAKE-but-calm hours, and sleep physiology (the natural HR/HRV swing between
    /// deep sleep and REM, the cortisol-driven rise approaching wake) is not what that reference
    /// models — scoring the night against it would misread ordinary sleep-stage variation as
    /// stress, the exact failure `analyze`'s sleep-masking guards against on the other side. This
    /// function instead gives sleep its OWN internally-consistent reference (quietest stretch of
    /// THIS night = calm, by the same quartile method `analyze` already uses for daytime), so a
    /// night that was genuinely restless shows elevated readings relative to ITS OWN quiet
    /// stretches, not relative to being awake.
    ///
    /// No activity gate: the wrist barely moves during real sleep, so the motion gate `analyze`
    /// needs for waking hours has nothing to mask here. No caching (unlike `analyze`): a sleep
    /// span is a handful of hourly buckets, not a full day's worth, and is read once per night
    /// rather than on every view re-evaluation.
    ///
    /// Returns hour buckets in time order, each possibly unscored (`level == nil`) when that hour
    /// had too little HR — never fabricated. Empty when the span is empty or carries no usable HR.
    public static func analyzeSleepWindow(hr: [HRSample], rr: [RRInterval],
                                          sleepSpan: (start: Int, end: Int),
                                          tzOffsetSeconds: Int = 0) -> [HourPoint] {
        guard sleepSpan.end > sleepSpan.start else { return [] }
        let hrInSpan = hr.filter { $0.ts >= sleepSpan.start && $0.ts < sleepSpan.end }
        guard !hrInSpan.isEmpty else { return [] }
        let rrInSpan = rr.filter { $0.ts >= sleepSpan.start && $0.ts < sleepSpan.end }

        var hrByBucket: [Int: [Double]] = [:]
        for s in hrInSpan { hrByBucket[bucketOf(s.ts + tzOffsetSeconds, phase: 0), default: []].append(Double(s.bpm)) }
        var rrByBucket: [Int: [Double]] = [:]
        for s in rrInSpan { rrByBucket[bucketOf(s.ts + tzOffsetSeconds, phase: 0), default: []].append(Double(s.rrMs)) }

        struct Agg { let bucket: Int; let meanHR: Double?; let rmssd: Double? }
        let aggs: [Agg] = hrByBucket.keys.sorted().map { b in
            let hrs = hrByBucket[b] ?? []
            let mHR = hrs.count >= minHourHRSamples ? cleanedMeanHR(hrs) : nil
            let rrRes = HRVAnalyzer.analyze(rawRR: rrByBucket[b] ?? [], minBeats: minDaytimeBucketRRBeats)
            return Agg(bucket: b, meanHR: mHR, rmssd: rrRes.rmssd)
        }
        guard !aggs.isEmpty else { return [] }

        let hrMeans = aggs.compactMap(\.meanHR)
        let rmssdVals = aggs.compactMap(\.rmssd)
        let refHR = calmReference(hrMeans, calmIsLow: true)
        let refRMSSD = calmReference(rmssdVals, calmIsLow: false)
        let sdHR = std(hrMeans, mean: mean(hrMeans))
        let sdRMSSD = std(rmssdVals, mean: mean(rmssdVals))

        return aggs.map { a in
            let wallStart = a.bucket - tzOffsetSeconds
            let level: Double? = a.meanHR != nil
                ? squash(rawScore(hr: a.meanHR, meanHR: refHR, sdHR: sdHR,
                                  rmssd: a.rmssd, meanRMSSD: refRMSSD, sdRMSSD: sdRMSSD))
                : nil
            return HourPoint(hour: hourOfDay(a.bucket), startTs: wallStart, level: level,
                             meanHR: a.meanHR, rmssd: a.rmssd)
        }
    }

    // MARK: - Helpers

    /// Floor-division that is correct for negative numerators (so a local time just before
    /// the UTC epoch still buckets to the hour below, not toward zero).
    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b, r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    /// The clock hour-of-day (0–23) a local-shifted bucket-start timestamp falls in. ALWAYS divides
    /// by a literal 3600, never by `bucketSeconds`: the old `floorDiv(bucket, bucketSeconds) % 24`
    /// only worked because bucket INDEX and HOUR happened to coincide when a bucket was exactly one
    /// hour wide (24 buckets/day). Now that `bucketSeconds` is 300 (288 buckets/day), that same
    /// expression wrapped every 24 buckets = 2 real hours — a real bug this change introduced and
    /// caught here before shipping, not a pre-existing one. `bucketSeconds` divides evenly into 3600
    /// (300 * 12 = 3600), so every bucket still falls inside exactly one clock hour.
    static func hourOfDay(_ bucket: Int) -> Int {
        floorDiv(bucket, 3_600) % 24
    }

    /// Whether a local hour-bucket start falls inside the waking window the timeline scores — the
    /// full day (see `wakingStartHour`/`wakingEndHour`'s own doc comment for why this is no longer a
    /// 06:00–22:00 cutoff). The single source of truth for "waking" — used both to build the calm
    /// reference and to pick the hours to score, so the two can never drift apart.
    static func isWakingHour(_ bucket: Int) -> Bool {
        let hour = hourOfDay(bucket)
        return hour >= wakingStartHour && hour < wakingEndHour
    }

    /// The day's "calm" reference for a signal: the quartile toward the calm end (lower
    /// quartile when calm is LOW, e.g. HR; upper quartile when calm is HIGH, e.g. RMSSD).
    /// Falls back to the plain mean below 4 values, and to nil when empty.
    static func calmReference(_ xs: [Double], calmIsLow: Bool) -> Double? {
        guard !xs.isEmpty else { return nil }
        guard xs.count >= 4 else { return mean(xs) }
        let s = xs.sorted()
        return calmIsLow ? quantile(s, 0.25) : quantile(s, 0.75)
    }

    /// Linear-interpolated quantile of an already-sorted, non-empty array.
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        let n = sorted.count
        guard n > 0 else { return 0 }   // defensive: callers guard emptiness; never trap on []
        if n == 1 { return sorted[0] }
        let pos = q * Double(n - 1)
        let lo = Int(pos), hi = min(lo + 1, n - 1)
        let frac = pos - Double(lo)
        return sorted[lo] + frac * (sorted[hi] - sorted[lo])
    }
}
