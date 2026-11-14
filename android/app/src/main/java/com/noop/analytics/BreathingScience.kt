package com.noop.analytics

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

// FORK: the Breathing tab's science-backed exercises and their maths. Twins of the fork Swift
// `BreathingScienceCatalog`, `BreathingProgression`, `BreathingHistory`, `BreathingSignal` and
// `BedtimeBreathingGate`. No CORE temperature sensor on this platform.

/** What a breathing exercise asks the user to do. */
sealed class BreathingDrill {
    data class Paced(val stages: List<BreathStage>) : BreathingDrill()
    data object ResonancePaced : BreathingDrill()
    data class ResonanceSweep(val secondsPerPace: Int) : BreathingDrill()
    data class BreathHolds(val rounds: Int, val recoverySeconds: Int, val maxHoldSeconds: Int) : BreathingDrill()
}

data class BreathingExercise(
    val id: String,
    val title: String,
    val subtitle: String,
    val benefits: List<String> = emptyList(),
    val howTo: String,
    val evidence: String,
    val caution: String? = null,
    val guidedSeconds: Int,
    val drill: BreathingDrill,
) {
    /** Breaths per minute of a paced drill (consecutive inhale stages count as one breath). */
    val pacedBreathsPerMinute: Double?
        get() {
            val stages = (drill as? BreathingDrill.Paced)?.stages ?: return null
            val cycleMs = stages.sumOf { it.durationMs }
            val breaths = stages.indices.count { i ->
                stages[i].type == BreathPhase.INHALE &&
                    stages[(i + stages.size - 1) % stages.size].type != BreathPhase.INHALE
            }
            if (cycleMs <= 0 || breaths <= 0) return null
            return breaths * 60_000.0 / cycleMs
        }

    /** The pacer protocol for this exercise, or null for drills the pacer cannot play (sweep, holds). */
    fun asProtocol(resonanceBpm: Double? = null): BreathProtocol? {
        val stages = when (val d = drill) {
            is BreathingDrill.Paced -> d.stages
            BreathingDrill.ResonancePaced -> {
                val bpm = resonanceBpm ?: ResonanceEngine.FALLBACK_BPM
                val halfMs = Math.round(60_000.0 / bpm / 2.0).toInt()
                listOf(BreathStage(BreathPhase.INHALE, halfMs), BreathStage(BreathPhase.EXHALE, halfMs))
            }
            else -> return null
        }
        return BreathProtocol(
            id = id, title = title, subtitle = subtitle, edu = howTo, caution = caution,
            mode = BreathProtocolMode.PLAYABLE, category = BreathProtocolCategory.ANS,
            recommendedDurationMs = guidedSeconds * 1000, stages = stages,
        )
    }
}

object BreathingProgression {
    data class State(val level: Int = 1, val completions: Int = 0)

    fun isProgressive(id: String): Boolean = maxLevel(id) > 1

    fun maxLevel(id: String): Int = when (id) {
        BreathingScienceCatalog.CO2_ID -> 5
        BreathingScienceCatalog.BREATH_HOLDS_ID -> 6
        BreathingScienceCatalog.RESPIRATORY_MUSCLE_ID -> 7
        else -> 1
    }

    fun sessionsPerLevel(id: String): Int = if (id == BreathingScienceCatalog.RESPIRATORY_MUSCLE_ID) 6 else 3

    fun co2HoldSeconds(level: Int): Int = 10 + 5 * (clamp(level, BreathingScienceCatalog.CO2_ID) - 1)

    fun breathHolds(level: Int): Pair<Int, Int> {
        val l = clamp(level, BreathingScienceCatalog.BREATH_HOLDS_ID) - 1
        return (5 + 2 * l) to (150 + 30 * l)
    }

    fun muscleBreaths(level: Int): Int = 30 + 5 * (clamp(level, BreathingScienceCatalog.RESPIRATORY_MUSCLE_ID) - 1)

    fun exercise(base: BreathingExercise, level: Int): BreathingExercise = when (base.id) {
        BreathingScienceCatalog.CO2_ID -> base.copy(
            drill = BreathingDrill.Paced(listOf(
                BreathStage(BreathPhase.INHALE, 6_000),
                BreathStage(BreathPhase.EXHALE, 6_000),
                BreathStage(BreathPhase.HOLD, co2HoldSeconds(level) * 1000, BreathingScienceCatalog.tr("Hold empty")),
            )),
        )
        BreathingScienceCatalog.BREATH_HOLDS_ID -> {
            val (rounds, maxHold) = breathHolds(level)
            base.copy(
                guidedSeconds = rounds * (120 + maxHold),
                drill = BreathingDrill.BreathHolds(rounds, 120, maxHold),
            )
        }
        BreathingScienceCatalog.RESPIRATORY_MUSCLE_ID -> base.copy(guidedSeconds = muscleBreaths(level) * 6)
        else -> base
    }

    fun afterSession(s: State, id: String, completedFully: Boolean): Pair<State, Boolean> {
        if (!isProgressive(id) || !completedFully) return s to false
        val next = State(clamp(s.level, id), s.completions + 1)
        if (next.completions < sessionsPerLevel(id) || next.level >= maxLevel(id)) return next to false
        return State(next.level + 1, 0) to true
    }

    fun stepDown(s: State, id: String): State = State(max(1, clamp(s.level, id) - 1), 0)

    internal fun clamp(level: Int, id: String): Int = min(max(level, 1), maxLevel(id))
}

object BreathingHistory {
    data class Entry(
        val ts: Long,
        val exerciseId: String,
        val guidedSeconds: Int,
        val avgCoherence: Double?,
        val avgHR: Double?,
        val freeAvgHR: Double?,
        val rmssd: Double?,
        val breathsPerMin: Double?,
    ) {
        val hrChange: Double? get() = if (freeAvgHR != null && avgHR != null) avgHR - freeAvgHR else null
    }

    const val MIN_GUIDED_SECONDS = 60
    const val TREND_WINDOW = 7
    const val MAX_ENTRIES = 500

    fun appending(new: Entry, entries: List<Entry>): List<Entry> {
        if (new.guidedSeconds < MIN_GUIDED_SECONDS) return entries
        return (entries + new).sortedBy { it.ts }.takeLast(MAX_ENTRIES)
    }

    fun trend(entries: List<Entry>, value: (Entry) -> Double?): Pair<Double, Double>? {
        val values = entries.sortedBy { it.ts }.mapNotNull(value)
        if (values.size < 2 * TREND_WINDOW) return null
        val recent = values.takeLast(TREND_WINDOW)
        val previous = values.dropLast(TREND_WINDOW).takeLast(TREND_WINDOW)
        return recent.average() to previous.average()
    }

    fun streakDays(entries: List<Entry>, today: java.time.LocalDate, zone: java.time.ZoneId): Int {
        val days = entries.map { java.time.Instant.ofEpochSecond(it.ts).atZone(zone).toLocalDate() }.toSet()
        var day = today
        if (day !in days) {
            if (day.minusDays(1) !in days) return 0
            day = day.minusDays(1)
        }
        var count = 0
        while (day in days) { count++; day = day.minusDays(1) }
        return count
    }

    fun sessionsLast7Days(entries: List<Entry>, nowSec: Long): Int =
        entries.count { it.ts > nowSec - 7 * 86_400 && it.ts <= nowSec }
}

object BreathingSignal {
    const val RESAMPLE_HZ = 4.0
    const val MIN_SPAN_SECONDS = 30.0
    const val MIN_BEATS = 20
    private val respBand = 0.05..0.5
    private const val SPECTRUM_LOW_HZ = 0.0033
    private val coherencePeakBand = 0.04..0.26
    private val coherenceTotalBand = 0.04..0.4
    private const val COHERENCE_PEAK_HALF_WIDTH_HZ = 0.015
    private const val GRID_STEP_HZ = 0.0025

    data class Spectrum(val freqs: List<Double>, val power: List<Double>)

    fun spectrum(rrMs: List<Double>): Spectrum? {
        val rr = HrvAnalyzer.cleanRR(rrMs)
        if (rr.size < MIN_BEATS) return null
        val t = ArrayList<Double>(rr.size)
        var acc = 0.0
        for (v in rr) { acc += v / 1000.0; t.add(acc) }
        val first = t.first()
        val last = t.last()
        if (last - first < MIN_SPAN_SECONDS) return null
        val dt = 1.0 / RESAMPLE_HZ
        val n = ((last - first) / dt).toInt() + 1
        val x = DoubleArray(n)
        var j = 0
        for (k in 0 until n) {
            val tk = first + k * dt
            while (j < t.size - 2 && t[j + 1] < tk) j++
            val span = t[j + 1] - t[j]
            val w = if (span > 0) (tk - t[j]) / span else 0.0
            x[k] = rr[j] + (rr[j + 1] - rr[j]) * min(max(w, 0.0), 1.0)
        }
        val meanK = (n - 1) / 2.0
        val meanX = x.average()
        var sxy = 0.0
        var sxx = 0.0
        for (k in 0 until n) {
            val dk = k - meanK
            sxy += dk * (x[k] - meanX); sxx += dk * dk
        }
        val slope = if (sxx > 0) sxy / sxx else 0.0
        for (k in 0 until n) {
            val hann = if (n > 1) 0.5 - 0.5 * cos(2.0 * PI * k / (n - 1)) else 1.0
            x[k] = (x[k] - meanX - slope * (k - meanK)) * hann
        }
        val freqs = ArrayList<Double>()
        val power = ArrayList<Double>()
        var f = SPECTRUM_LOW_HZ
        val top = max(respBand.endInclusive, coherenceTotalBand.endInclusive)
        while (f <= top + 1e-12) {
            var re = 0.0
            var im = 0.0
            val w = 2.0 * PI * f * dt
            for (k in 0 until n) {
                re += x[k] * cos(w * k)
                im -= x[k] * sin(w * k)
            }
            freqs.add(f)
            power.add((re * re + im * im) / n)
            f += GRID_STEP_HZ
        }
        return Spectrum(freqs, power)
    }

    fun breathsPerMinute(rrMs: List<Double>): Double? {
        val s = spectrum(rrMs) ?: return null
        return peakHz(s, respBand)?.let { it * 60.0 }
    }

    /** Share (0–100) of the 0.04–0.4 Hz power sitting in the dominant slow-breathing peak. */
    fun coherence(rrMs: List<Double>): Double? {
        val s = spectrum(rrMs) ?: return null
        val hz = peakHz(s, coherencePeakBand) ?: return null
        var peak = 0.0
        var total = 0.0
        for (i in s.freqs.indices) {
            val f = s.freqs[i]
            val p = s.power[i]
            if (f in coherenceTotalBand) total += p
            if (abs(f - hz) <= COHERENCE_PEAK_HALF_WIDTH_HZ) peak += p
        }
        if (total <= 0) return null
        return min(100.0, 100.0 * peak / total)
    }

    internal fun peakHz(s: Spectrum, band: ClosedFloatingPointRange<Double>): Double? {
        var best = -1
        for (i in s.freqs.indices) {
            if (s.freqs[i] in band && (best < 0 || s.power[i] > s.power[best])) best = i
        }
        if (best < 0 || s.power[best] <= 0) return null
        if (best == 0 || best == s.freqs.size - 1) return s.freqs[best]
        val a = s.power[best - 1]
        val b = s.power[best]
        val c = s.power[best + 1]
        val denom = a - 2 * b + c
        val shift = if (denom != 0.0) 0.5 * (a - c) / denom else 0.0
        return s.freqs[best] + min(max(shift, -0.5), 0.5) * GRID_STEP_HZ
    }
}

object BedtimeBreathingGate {
    val WINDOW_MINUTES = (21 * 60) until (23 * 60)
    const val LOOKBACK_SECONDS = 15 * 60
    const val MIN_COVERED_MINUTES = 10
    const val MIN_STILL_FRACTION = 0.8
    const val STILL_MAX_DEVIATION_G = 0.05
    const val ASLEEP_MAX_BPM_ABOVE_RESTING = 4.0
    const val MAX_BPM_ABOVE_RESTING = 30.0
    const val MIN_BPM_DROP_WITHOUT_RESTING = 3.0

    enum class Verdict { NUDGE, OUTSIDE_WINDOW, NOT_ENOUGH_DATA, MOVING, HEART_RATE_HIGH, ASLEEP }

    /** Whether the wearer is lying still but still awake between 21:00 and 23:00. */
    fun evaluate(
        now: Long,
        localMinuteOfDay: Int,
        hr: List<com.noop.data.HrSample>,
        grav: List<com.noop.data.GravitySample>,
        restingHR: Double?,
    ): Verdict {
        if (localMinuteOfDay !in WINDOW_MINUTES) return Verdict.OUTSIDE_WINDOW
        val from = now - LOOKBACK_SECONDS
        val g = grav.filter { it.ts > from && it.ts <= now }
        val h = hr.filter { it.ts > from && it.ts <= now && it.bpm > 0 }
        val byMinute = g.groupBy { ((it.ts - from) / 60).toInt() }.values.filter { it.isNotEmpty() }
        if (byMinute.size < MIN_COVERED_MINUTES || h.size < 10) return Verdict.NOT_ENOUGH_DATA
        val still = byMinute.count(::isStill)
        if (still.toDouble() / byMinute.size < MIN_STILL_FRACTION) return Verdict.MOVING
        val recent = h.filter { it.ts > now - 10 * 60 }.map { it.bpm.toDouble() }
        val recentMedian = median(recent) ?: return Verdict.NOT_ENOUGH_DATA
        if (restingHR != null && restingHR > 0) {
            if (recentMedian <= restingHR + ASLEEP_MAX_BPM_ABOVE_RESTING) return Verdict.ASLEEP
            return if (recentMedian <= restingHR + MAX_BPM_ABOVE_RESTING) Verdict.NUDGE else Verdict.HEART_RATE_HIGH
        }
        val earlier = median(h.filter { it.ts <= now - 10 * 60 }.map { it.bpm.toDouble() }) ?: return Verdict.NOT_ENOUGH_DATA
        return if (recentMedian <= earlier - MIN_BPM_DROP_WITHOUT_RESTING) Verdict.NUDGE else Verdict.HEART_RATE_HIGH
    }

    private fun isStill(minute: List<com.noop.data.GravitySample>): Boolean {
        val n = minute.size.toDouble()
        val mx = minute.sumOf { it.x.toDouble() } / n
        val my = minute.sumOf { it.y.toDouble() } / n
        val mz = minute.sumOf { it.z.toDouble() } / n
        return minute.all {
            val dx = it.x - mx
            val dy = it.y - my
            val dz = it.z - mz
            sqrt(dx * dx + dy * dy + dz * dz) <= STILL_MAX_DEVIATION_G
        }
    }

    private fun median(v: List<Double>): Double? {
        if (v.isEmpty()) return null
        val s = v.sorted()
        return if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2
    }
}
