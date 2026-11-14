package com.noop.analytics

import java.util.Locale
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.roundToInt

// FORK: Kotlin twins of the fork's small StrandAnalytics additions (BedtimeRecommendation, PaceOfRecovery,
// RaceTimePredictor, ResilienceEngine, EarlyNightRecovery, NightExplainer, AlarmWakeQuality) and of the
// pure policies inside the iOS SleepRecap/Trend/Overload notifiers. Same constants and the same math as
// the Swift sources, so both apps read the same numbers off the same data.

/** Tonight's bedtime from sleep debt + habitual wake time. Twin of Swift `BedtimeRecommendation`. */
object BedtimeRecommendation {
    data class Result(val bedtimeMinutes: Int, val targetSleepMin: Double, val debtOwedMin: Double)

    const val MAX_DEBT_REPAY_MIN: Double = 60.0

    fun recommend(debtBalanceMin: Double, baseNeedMin: Double, habitualWakeMinutes: Int): Result {
        val owed = minOf(MAX_DEBT_REPAY_MIN, maxOf(0.0, -debtBalanceMin))
        val targetMin = baseNeedMin + owed
        val raw = habitualWakeMinutes - Math.round(targetMin).toInt()
        val bedtime = ((raw % 1440) + 1440) % 1440
        return Result(bedtime, targetMin, owed)
    }

    fun formatClock(minutesSinceMidnight: Int): String {
        val m = ((minutesSinceMidnight % 1440) + 1440) % 1440
        return String.format(Locale.ROOT, "%02d:%02d", m / 60, m % 60)
    }
}

/** Days until TSB climbs back to 0 with no further load. Twin of Swift `PaceOfRecovery`. */
object PaceOfRecovery {
    data class Projection(val daysToRecovered: Int, val currentTSB: Double)

    const val TARGET_TSB: Double = 0.0
    const val MAX_PROJECTED_DAYS: Int = 21

    fun project(
        ctl: Double,
        atl: Double,
        chronicTimeConstantDays: Double = TrainingLoadEngine.standard.chronicTimeConstantDays,
        acuteTimeConstantDays: Double = TrainingLoadEngine.standard.acuteTimeConstantDays,
    ): Projection {
        val tsbNow = ctl - atl
        if (tsbNow >= TARGET_TSB) return Projection(0, tsbNow)
        for (day in 1..MAX_PROJECTED_DAYS) {
            val k = day.toDouble()
            val ctlK = ctl * exp(-k / chronicTimeConstantDays)
            val atlK = atl * exp(-k / acuteTimeConstantDays)
            if (ctlK - atlK >= TARGET_TSB) return Projection(day, tsbNow)
        }
        return Projection(MAX_PROJECTED_DAYS, tsbNow)
    }
}

/** Race times from VO2max (ACSM running economy + sustainable fraction). Twin of Swift `RaceTimePredictor`. */
object RaceTimePredictor {
    private const val ACSM_SLOPE = 0.2
    private const val ACSM_INTERCEPT = 3.5

    data class Distance(val label: String, val meters: Double, val vo2maxFraction: Double)
    data class Estimate(val distance: Distance, val seconds: Double)

    val standardDistances = listOf(
        Distance("5K", 5_000.0, 0.95),
        Distance("10K", 10_000.0, 0.90),
        Distance("Semi-marathon", 21_097.0, 0.85),
        Distance("Marathon", 42_195.0, 0.75),
    )

    fun estimate(vo2max: Double, distances: List<Distance> = standardDistances): List<Estimate> =
        distances.mapNotNull { d ->
            val speed = (vo2max * d.vo2maxFraction - ACSM_INTERCEPT) / ACSM_SLOPE
            if (speed <= 0) null else Estimate(d, d.meters / speed * 60.0)
        }

    fun formatDuration(seconds: Double): String {
        val total = seconds.roundToInt()
        val h = total / 3600
        val m = (total % 3600) / 60
        val s = total % 60
        return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, s)
        else String.format(Locale.ROOT, "%d:%02d", m, s)
    }
}

/** Mean Charge on the higher-stress days of the last 14. Twin of Swift `ResilienceEngine`. */
object ResilienceEngine {
    data class DayInput(val day: String, val stress: Double?, val recovery: Double?)
    enum class Band { LIMITED, ADEQUATE, SOLID, STRONG, EXCEPTIONAL }
    data class Result(val resilienceScore: Double, val band: Band, val higherStressDayCount: Int)

    const val DEFAULT_WINDOW_DAYS = 14
    const val MIN_QUALIFYING_DAYS = 4
    const val HIGHER_STRESS_THRESHOLD = 2.0

    fun evaluate(days: List<DayInput>, window: Int = DEFAULT_WINDOW_DAYS): Result? {
        val trailing = days.sortedBy { it.day }.takeLast(window)
        val qualifying = trailing.mapNotNull { d ->
            val s = d.stress ?: return@mapNotNull null
            val r = d.recovery ?: return@mapNotNull null
            if (s >= HIGHER_STRESS_THRESHOLD) r else null
        }
        if (qualifying.size < MIN_QUALIFYING_DAYS) return null
        val mean = qualifying.sum() / qualifying.size
        return Result(mean, band(mean), qualifying.size)
    }

    fun band(score: Double): Band = when {
        score < 34 -> Band.LIMITED
        score < 50 -> Band.ADEQUATE
        score < 67 -> Band.SOLID
        score < 85 -> Band.STRONG
        else -> Band.EXCEPTIONAL
    }

    fun bandLabelFr(band: Band): String = when (band) {
        Band.LIMITED -> "Limitée"
        Band.ADEQUATE -> "Correcte"
        Band.SOLID -> "Solide"
        Band.STRONG -> "Forte"
        Band.EXCEPTIONAL -> "Exceptionnelle"
    }
}

/** First-4-hours RMSSD against the whole night. Twin of Swift `EarlyNightRecovery`. */
object EarlyNightRecovery {
    const val EARLY_WINDOW_MINUTES = 240
    const val MIN_INTERVALS_PER_WINDOW = 30

    data class Result(val earlyRMSSD: Double, val fullNightRMSSD: Double) {
        val ratio: Double get() = if (fullNightRMSSD > 0) earlyRMSSD / fullNightRMSSD else 1.0
    }

    fun evaluate(earlyNN: List<Double>, fullNightNN: List<Double>): Result? {
        if (earlyNN.size < MIN_INTERVALS_PER_WINDOW || fullNightNN.size < MIN_INTERVALS_PER_WINDOW) return null
        val early = HrvAnalyzer.rmssdRaw(earlyNN) ?: return null
        val full = HrvAnalyzer.rmssdRaw(fullNightNN) ?: return null
        return Result(early, full)
    }
}

/** One-sentence possible contributor for a low night. Twin of Swift `NightExplainer`. */
object NightExplainer {
    const val NOTABLE_Z_THRESHOLD = 1.0

    fun explain(loggedFactors: List<String>, hrvZ: Double?, rhrZ: Double?): String? {
        val parts = loggedFactors.toMutableList()
        if (hrvZ != null && hrvZ <= -NOTABLE_Z_THRESHOLD) parts.add("une HRV sous votre habitude")
        if (rhrZ != null && rhrZ <= -NOTABLE_Z_THRESHOLD) parts.add("une FC de repos au-dessus de votre habitude")
        if (parts.isEmpty()) return null
        if (parts.size == 1) return "Possible facteur : ${parts[0]}."
        return "Possibles facteurs : ${parts.dropLast(1).joinToString(", ")} et ${parts.last()}."
    }
}

/** Stage the fixed alarm time fell in (instrumentation only). Twin of Swift `AlarmWakeQuality`. */
object AlarmWakeQuality {
    enum class Verdict { LIGHT, DEEP, REM, WAKE, UNKNOWN }

    fun stageAtAlarm(
        segments: List<StageSegment>,
        sessionEndTs: Long,
        alarmMinutesSinceMidnight: Int,
        tzOffsetSeconds: Int,
    ): Verdict? {
        val localEnd = sessionEndTs + tzOffsetSeconds
        val localDayStart = Math.floorDiv(localEnd, 86_400L) * 86_400L
        val alarmUtc = localDayStart + alarmMinutesSinceMidnight * 60L - tzOffsetSeconds
        val seg = segments.firstOrNull { alarmUtc >= it.start && alarmUtc < it.end } ?: return null
        return when (seg.stage) {
            "light" -> Verdict.LIGHT
            "deep" -> Verdict.DEEP
            "rem" -> Verdict.REM
            "wake" -> Verdict.WAKE
            else -> Verdict.UNKNOWN
        }
    }
}

/** HRV streak above/below the personal baseline. Twin of the iOS `TrendNotifier.currentStreak`. */
object HrvTrendStreak {
    const val MIN_STREAK_NIGHTS = 3
    const val Z_THRESHOLD = 1.0

    data class Streak(val count: Int, val aboveBaseline: Boolean, val avgRatio: Double)

    fun currentStreak(values: List<Double?>): Streak? {
        if (values.isEmpty()) return null
        val before = ArrayList<BaselineState?>(values.size)
        var state: BaselineState? = null
        for (v in values) {
            before.add(state)
            state = Baselines.update(state, v, Baselines.hrvCfg)
        }
        var count = 0
        var above = true
        var ratioSum = 0.0
        for (i in values.indices.reversed()) {
            val v = values[i] ?: break
            val b = before[i] ?: break
            if (!b.usable) break
            val dev = Baselines.deviation(v, b)
            if (abs(dev.z) < Z_THRESHOLD) break
            val isAbove = dev.z > 0
            if (count == 0) above = isAbove else if (isAbove != above) break
            count++
            ratioSum += dev.ratio
        }
        return if (count == 0) null else Streak(count, above, ratioSum / count)
    }
}

/** Effort above the recovery-derived optimal band, several days running. Twin of iOS `OverloadPolicy`. */
object OverloadPolicy {
    const val REQUIRED_STREAK = 3

    data class Day(val day: String, val strain21: Double?, val upperBound21: Int?)

    fun isOverloaded(strain21: Double?, upperBound21: Int?): Boolean =
        strain21 != null && upperBound21 != null && strain21 > upperBound21.toDouble()

    fun currentStreak(days: List<Day>): Int {
        var streak = 0
        for (d in days.sortedByDescending { it.day }) {
            if (!isOverloaded(d.strain21, d.upperBound21)) break
            streak++
        }
        return streak
    }

    fun shouldNotify(enabled: Boolean, streak: Int, lastNotifiedDay: String?, today: String): Boolean =
        enabled && streak >= REQUIRED_STREAK && lastNotifiedDay != today
}

/** What shaped today's Effort: inputs used, zone minutes, raw vs sustained peak. Twin of the fork's
 *  Swift `StrainScorer.breakdown`; the score comes from [StrainScorer.strain] with the SAME inputs, so the
 *  sheet always explains the number on the ring. */
object EffortBreakdownCalc {
    data class Breakdown(
        val hrMaxUsed: Double,
        val restingHRUsed: Double,
        val method: StrainScorer.Method,
        val strain: Double,
        /** [0] below zone 1, [1..5] zones 1-5, minutes. */
        val zoneMinutes: List<Double>,
        val peakBpm: Double?,
        val sustainedPeakBpm: Double?,
    )

    fun breakdown(
        hr: List<com.noop.data.HrSample>,
        maxHR: Double?,
        restingHR: Double,
        method: StrainScorer.Method,
        sex: String,
    ): Breakdown? {
        val s = StrainScorer.strain(hr = hr, maxHR = maxHR, restingHR = restingHR, method = method, sex = sex) ?: return null
        val effMax = maxHR ?: StrainScorer.defaultMaxHR().toDouble()
        val zones = StrainScorer.zoneMinutes(hr, restingHR, effMax - restingHR, StrainScorer.sampleDurationsMinutes(hr))
        return Breakdown(effMax, restingHR, method, s, zones, hr.maxOfOrNull { it.bpm.toDouble() }, StrainScorer.sustainedPeak(hr))
    }
}
