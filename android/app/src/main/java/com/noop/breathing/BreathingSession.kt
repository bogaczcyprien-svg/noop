package com.noop.breathing

import android.content.Context
import com.noop.analytics.BreathPhase
import com.noop.analytics.BreathStage
import com.noop.analytics.BreathingDrill
import com.noop.analytics.BreathingExercise
import com.noop.analytics.BreathingHistory
import com.noop.analytics.BreathingProgression
import com.noop.analytics.BreathingScienceCatalog.tr
import com.noop.analytics.BreathingSignal
import com.noop.analytics.HrvAnalyzer
import com.noop.analytics.ResonanceEngine
import com.noop.ingest.BreathingFitExporter
import com.noop.intervals.IntervalsIcuHttpException
import com.noop.intervals.IntervalsIcuSettings
import com.noop.ui.AppViewModel
import com.noop.ui.BiofeedbackPrefs
import com.noop.ui.HapticPrefs
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import kotlin.math.ceil

/** FORK: per-exercise level persistence. Twin of the fork iOS `BreathingLevelStore`. */
object BreathingLevelStore {
    private fun key(id: String) = "noop.breathing.level.$id"
    fun state(ctx: Context, id: String): BreathingProgression.State {
        val raw = NoopPrefs.of(ctx).getString(key(id), null) ?: return BreathingProgression.State()
        return runCatching {
            val o = JSONObject(raw)
            BreathingProgression.State(o.optInt("level", 1), o.optInt("completions", 0))
        }.getOrDefault(BreathingProgression.State())
    }
    fun save(ctx: Context, s: BreathingProgression.State, id: String) {
        NoopPrefs.of(ctx).edit().putString(key(id), JSONObject().put("level", s.level).put("completions", s.completions).toString()).apply()
    }
    fun current(ctx: Context, ex: BreathingExercise): BreathingExercise =
        BreathingProgression.exercise(ex, state(ctx, ex.id).level)
}

/** FORK: the session history list, kept in prefs as JSON. Twin of the fork iOS `BreathingHistoryStore`. */
object BreathingHistoryStore {
    private const val KEY = "noop.breathing.history"
    fun load(ctx: Context): List<BreathingHistory.Entry> = runCatching {
        val arr = JSONArray(NoopPrefs.of(ctx).getString(KEY, "[]"))
        (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            fun d(n: String) = if (o.isNull(n) || !o.has(n)) null else o.getDouble(n)
            BreathingHistory.Entry(o.getLong("ts"), o.getString("exerciseId"), o.getInt("guidedSeconds"),
                d("avgCoherence"), d("avgHR"), d("freeAvgHR"), d("rmssd"), d("breathsPerMin"))
        }
    }.getOrDefault(emptyList())

    fun append(ctx: Context, e: BreathingHistory.Entry) {
        val all = BreathingHistory.appending(e, load(ctx))
        val arr = JSONArray()
        for (x in all) {
            arr.put(JSONObject().put("ts", x.ts).put("exerciseId", x.exerciseId).put("guidedSeconds", x.guidedSeconds)
                .put("avgCoherence", x.avgCoherence ?: JSONObject.NULL).put("avgHR", x.avgHR ?: JSONObject.NULL)
                .put("freeAvgHR", x.freeAvgHR ?: JSONObject.NULL).put("rmssd", x.rmssd ?: JSONObject.NULL)
                .put("breathsPerMin", x.breathsPerMin ?: JSONObject.NULL))
        }
        NoopPrefs.of(ctx).edit().putString(KEY, arr.toString()).apply()
    }
}

/**
 * FORK: one breathing session — optional free breathing, then the guided part (paced, resonance pace,
 * resonance sweep or breath-hold series) — reading the strap's live beat-to-beat data for breathing rate,
 * RMSSD and coherence. Twin of the fork iOS `BreathingSessionModel`, minus the CORE sensor.
 */
class BreathingSession(
    private val ctx: Context,
    private val vm: AppViewModel,
    val exercise: BreathingExercise,
    val freeSeconds: Int,
    private val scope: CoroutineScope,
) {
    sealed class Part {
        data object Free : Part()
        data object Guided : Part()
        data class Recovery(val round: Int) : Part()
        data class Hold(val round: Int) : Part()
        data object Done : Part()
    }

    data class Pacer(val phase: BreathPhase, val label: String?, val fill: Double, val secondsLeft: Int)

    data class PartStats(
        val seconds: Int = 0,
        val avgHR: Double? = null,
        val minHR: Int? = null,
        val avgBreathsPerMin: Double? = null,
        val rmssd: Double? = null,
        val avgCoherence: Double? = null,
    )

    data class Progression(val levelBefore: Int, val after: BreathingProgression.State, val leveledUp: Boolean, val completedFully: Boolean)

    data class Summary(
        val free: PartStats,
        val guided: PartStats,
        val holdsSeconds: List<Int>,
        val resonanceBpm: Double?,
        val resonanceLocked: Boolean,
        val totalSeconds: Int,
        val progression: Progression?,
    )

    sealed class Upload {
        data object NotConfigured : Upload()
        data object Sending : Upload()
        data object Sent : Upload()
        data class Failed(val reason: String) : Upload()
    }

    data class Ui(
        val part: Part = Part.Free,
        val partElapsed: Int = 0,
        val totalElapsed: Int = 0,
        val heartRate: Int? = null,
        val breathsPerMin: Double? = null,
        val coherence: Double? = null,
        val rmssd: Double? = null,
        val holdsSeconds: List<Int> = emptyList(),
        val pacer: Pacer? = null,
        val sweepPace: Double? = null,
        val summary: Summary? = null,
        val upload: Upload = Upload.NotConfigured,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui: StateFlow<Ui> = _ui

    private val startMs = System.currentTimeMillis()
    private var partStartMs = startMs
    private var guidedStartMs: Long? = null
    private var part: Part = Part.Free
    private val holds = ArrayList<Int>()
    private val samples = ArrayList<BreathingFitExporter.Sample>()
    private val sampleIsGuided = ArrayList<Boolean>()
    private val coherenceReadings = ArrayList<Pair<Boolean, Double>>()
    private val beats = ArrayList<Pair<Double, Int>>() // (unix seconds, rr ms)
    private var lastRrSeq = -1L
    private var lastStageKey: String? = null
    private var breathsPerMin: Double? = null
    private var coherence: Double? = null
    private var rmssd: Double? = null
    private val guidedProtocolStages: List<BreathStage>? =
        exercise.asProtocol(BiofeedbackPrefs.lockedPace(ctx))?.stages
    private var job: Job? = null

    val guidedSeconds: Int
        get() = when (val d = exercise.drill) {
            is BreathingDrill.ResonanceSweep -> d.secondsPerPace * ResonanceEngine.FULL_SWEEP_PACES.size
            is BreathingDrill.BreathHolds -> d.rounds * (d.recoverySeconds + d.maxHoldSeconds)
            else -> exercise.guidedSeconds
        }

    private val holdCapSeconds: Int get() = (exercise.drill as? BreathingDrill.BreathHolds)?.maxHoldSeconds ?: 0

    fun start() {
        if (freeSeconds > 0) enter(Part.Free) else startGuided()
        job = scope.launch {
            var tick = 0
            while (part != Part.Done) {
                takeLiveRr()
                if (tick % 10 == 0) secondTick()
                pacerTick()
                tick++
                delay(100)
            }
        }
    }

    fun skipFree() { if (part == Part.Free) startGuided() }

    fun endHold() {
        val p = part as? Part.Hold ?: return
        holds += elapsed(partStartMs)
        nextAfterHold(p.round)
    }

    fun stop() {
        if (part is Part.Hold) holds += elapsed(partStartMs)
        finish(completed = false)
    }

    fun retryUpload() {
        val s = _ui.value.summary ?: return
        if (_ui.value.upload is Upload.Failed) scope.launch { post(s) }
    }

    private fun elapsed(fromMs: Long) = ((System.currentTimeMillis() - fromMs) / 1000).toInt()

    private fun pacerAt(nowMs: Long): Pacer? = when (val p = part) {
        Part.Free, Part.Done -> null
        is Part.Hold -> Pacer(BreathPhase.HOLD, tr("Hold"), 1.0, maxOf(0, holdCapSeconds - ((nowMs - partStartMs) / 1000).toInt()))
        is Part.Recovery -> cyclePacer(RECOVERY_STAGES, (nowMs - partStartMs).toInt())
        Part.Guided -> {
            val g = guidedStartMs
            if (g == null) null else {
                val ms = (nowMs - g).toInt()
                val d = exercise.drill
                if (d is BreathingDrill.ResonanceSweep) {
                    val paces = ResonanceEngine.FULL_SWEEP_PACES
                    val index = minOf(paces.size - 1, ms / (d.secondsPerPace * 1000))
                    val half = Math.round(60_000.0 / paces[index] / 2).toInt()
                    cyclePacer(listOf(BreathStage(BreathPhase.INHALE, half), BreathStage(BreathPhase.EXHALE, half)),
                        ms - index * d.secondsPerPace * 1000)
                } else {
                    guidedProtocolStages?.takeIf { it.isNotEmpty() }?.let { cyclePacer(it, ms) }
                }
            }
        }
    }

    private val sweepPace: Double?
        get() {
            val d = exercise.drill as? BreathingDrill.ResonanceSweep ?: return null
            val g = guidedStartMs ?: return null
            if (part != Part.Guided) return null
            val paces = ResonanceEngine.FULL_SWEEP_PACES
            return paces[minOf(paces.size - 1, elapsed(g) / d.secondsPerPace)]
        }

    private fun cyclePacer(stages: List<BreathStage>, elapsedMs: Int): Pacer? {
        val cycle = stages.sumOf { it.durationMs }
        if (cycle <= 0) return null
        var t = ((elapsedMs % cycle) + cycle) % cycle
        var level = 0.0
        for ((i, s) in stages.withIndex()) {
            val nextIsInhale = stages.getOrNull(i + 1)?.type == BreathPhase.INHALE
            if (t < s.durationMs) {
                val p = if (s.durationMs > 0) t.toDouble() / s.durationMs else 1.0
                val fill = when (s.type) {
                    BreathPhase.INHALE -> level + ((if (nextIsInhale) 0.8 else 1.0) - level) * p
                    BreathPhase.EXHALE -> level * (1 - p)
                    else -> level
                }
                return Pacer(s.type, s.label, fill, ceil((s.durationMs - t) / 1000.0).toInt())
            }
            t -= s.durationMs
            when (s.type) {
                BreathPhase.INHALE -> level = if (nextIsInhale) 0.8 else 1.0
                BreathPhase.EXHALE -> level = 0.0
                else -> Unit
            }
        }
        return null
    }

    private fun secondTick() {
        if (part == Part.Done) return
        val nowMs = System.currentTimeMillis()
        val total = elapsed(startMs)
        val partElapsed = elapsed(partStartMs)
        val hr = vm.live.value.heartRate
        if (total % 5 == 0) refreshReadings(nowMs / 1000.0)
        val guided = part != Part.Free
        var bpm = breathsPerMin
        if (part is Part.Hold) bpm = null else if (bpm == null && guided) bpm = guidedPaceNow
        samples += BreathingFitExporter.Sample(nowMs / 1000, hr, bpm)
        sampleIsGuided += guided
        _ui.value = _ui.value.copy(part = part, partElapsed = partElapsed, totalElapsed = total, heartRate = hr,
            breathsPerMin = breathsPerMin, coherence = coherence, rmssd = rmssd, holdsSeconds = holds.toList(),
            sweepPace = sweepPace)
        when (val p = part) {
            Part.Free -> if (partElapsed >= freeSeconds) startGuided()
            Part.Guided -> if (partElapsed >= guidedSeconds) finish(completed = true)
            is Part.Recovery -> {
                val d = exercise.drill
                if (d is BreathingDrill.BreathHolds && partElapsed >= d.recoverySeconds) enter(Part.Hold(p.round))
            }
            is Part.Hold -> if (partElapsed >= holdCapSeconds) { holds += partElapsed; nextAfterHold(p.round) }
            Part.Done -> Unit
        }
    }

    private val guidedPaceNow: Double?
        get() = when (exercise.drill) {
            is BreathingDrill.Paced -> exercise.pacedBreathsPerMinute
            BreathingDrill.ResonancePaced -> BiofeedbackPrefs.lockedPace(ctx) ?: ResonanceEngine.FALLBACK_BPM
            is BreathingDrill.ResonanceSweep -> sweepPace
            is BreathingDrill.BreathHolds -> 6.0
        }

    private fun pacerTick() {
        val p = pacerAt(System.currentTimeMillis())
        _ui.value = _ui.value.copy(pacer = p)
        if (p == null) { lastStageKey = null; return }
        val key = "${p.phase}|${p.label ?: ""}|$part"
        if (key == lastStageKey) return
        val first = lastStageKey == null
        lastStageKey = key
        if (first || !vm.live.value.encryptedBond) return
        vm.buzz(loops = if (p.phase == BreathPhase.EXHALE) 2 else 1, gate = HapticPrefs.BREATHING)
    }

    private fun refreshReadings(now: Double) {
        val from = maxOf(now - 64, if (part == Part.Free) 0.0 else (guidedStartMs ?: 0L) / 1000.0)
        val window = beats.filter { it.first > from }.map { it.second.toDouble() }
        breathsPerMin = BreathingSignal.breathsPerMinute(window)
        coherence = BreathingSignal.coherence(window)
        rmssd = HrvAnalyzer.rmssdRaw(HrvAnalyzer.cleanRR(window))
        coherence?.let { coherenceReadings += (part != Part.Free) to it }
    }

    /** Appends each new live R-R packet, back-dating its beats from now. */
    private fun takeLiveRr() {
        if (part == Part.Done) return
        val live = vm.live.value
        if (live.rrSeq == lastRrSeq) return
        val first = lastRrSeq < 0
        lastRrSeq = live.rrSeq
        if (first) return
        var t = System.currentTimeMillis() / 1000.0
        val batch = ArrayList<Pair<Double, Int>>()
        for (rr in live.rr.asReversed()) if (rr > 0) { batch += t to rr; t -= rr / 1000.0 }
        beats += batch.asReversed()
    }

    private fun enter(p: Part) {
        part = p
        partStartMs = System.currentTimeMillis()
        _ui.value = _ui.value.copy(part = p, partElapsed = 0)
    }

    private fun startGuided() {
        guidedStartMs = System.currentTimeMillis()
        if (exercise.drill is BreathingDrill.BreathHolds) enter(Part.Recovery(1)) else enter(Part.Guided)
    }

    private fun nextAfterHold(round: Int) {
        val d = exercise.drill
        if (d is BreathingDrill.BreathHolds && round < d.rounds) enter(Part.Recovery(round + 1)) else finish(completed = true)
    }

    private fun finish(completed: Boolean) {
        if (part == Part.Done) return
        val endMs = System.currentTimeMillis()
        part = Part.Done
        val guidedFrom = (guidedStartMs ?: endMs) / 1000.0
        val free = stats(false, startMs / 1000.0, guidedFrom)
        val guided = stats(true, guidedFrom, endMs / 1000.0)
        var resonanceBpm: Double? = null
        var locked = false
        val d = exercise.drill
        val g = guidedStartMs
        if (d is BreathingDrill.ResonanceSweep && g != null) {
            val paceSamples = ResonanceEngine.FULL_SWEEP_PACES.mapIndexed { i, bpm ->
                val from = g / 1000.0 + i * d.secondsPerPace
                val to = from + d.secondsPerPace
                val rr = beats.filter { it.first >= from && it.first < to }.map { ResonanceEngine.RrBeat(it.first.toInt(), it.second) }
                ResonanceEngine.PaceSample(bpm, rr, from.toInt(), to.toInt())
            }
            val result = ResonanceEngine.sweep(paceSamples)
            resonanceBpm = result.lockedBpm
            locked = result.didLock
            if (result.didLock) BiofeedbackPrefs.saveLockedPace(ctx, result.lockedBpm, endMs)
        }
        var progression: Progression? = null
        if (BreathingProgression.isProgressive(exercise.id)) {
            val before = BreathingLevelStore.state(ctx, exercise.id)
            val (after, up) = BreathingProgression.afterSession(before, exercise.id, completed)
            BreathingLevelStore.save(ctx, after, exercise.id)
            progression = Progression(before.level, after, up, completed)
        }
        val summary = Summary(free, guided, holds.toList(), resonanceBpm, locked, ((endMs - startMs) / 1000).toInt(), progression)
        _ui.value = _ui.value.copy(part = Part.Done, pacer = null, summary = summary)
        BreathingHistoryStore.append(ctx, BreathingHistory.Entry(
            startMs / 1000, exercise.id, guided.seconds, guided.avgCoherence, guided.avgHR,
            if (free.seconds > 0) free.avgHR else null, guided.rmssd, guided.avgBreathsPerMin,
        ))
        if (summary.totalSeconds >= 60) scope.launch { post(summary) }
    }

    private fun stats(guided: Boolean, from: Double, to: Double): PartStats {
        val rows = samples.indices.filter { sampleIsGuided[it] == guided }.map { samples[it] }
        val hrs = rows.mapNotNull { it.hr }
        val rr = beats.filter { it.first >= from && it.first < to }.map { it.second.toDouble() }
        val resp = rows.mapNotNull { it.breathsPerMin }
        val coh = coherenceReadings.filter { it.first == guided }.map { it.second }
        return PartStats(
            seconds = rows.size,
            avgHR = if (hrs.isEmpty()) null else hrs.average(),
            minHR = hrs.minOrNull(),
            avgBreathsPerMin = if (resp.isEmpty()) null else resp.average(),
            rmssd = HrvAnalyzer.rmssdRaw(HrvAnalyzer.cleanRR(rr)),
            avgCoherence = if (coh.isEmpty()) null else coh.average(),
        )
    }

    private suspend fun post(s: Summary) {
        val client = IntervalsIcuSettings.client(ctx)
        if (client == null) { _ui.value = _ui.value.copy(upload = Upload.NotConfigured); return }
        _ui.value = _ui.value.copy(upload = Upload.Sending)
        val startTs = startMs / 1000
        val fit = BreathingFitExporter.build(samples, beats.map { it.second }, startTs, startTs + s.totalSeconds)
        val upload = try {
            client.uploadActivity(fit, "noop-breathing-$startTs.fit", "${tr("Breathing")} · ${exercise.title}",
                BreathingSessionText.description(s, exercise))
            Upload.Sent
        } catch (e: IntervalsIcuHttpException) {
            Upload.Failed("HTTP ${e.code}")
        } catch (e: Exception) {
            Upload.Failed(e.message ?: e.javaClass.simpleName)
        }
        _ui.value = _ui.value.copy(upload = upload)
    }

    companion object {
        private val RECOVERY_STAGES = listOf(BreathStage(BreathPhase.INHALE, 4_000), BreathStage(BreathPhase.EXHALE, 6_000))
    }
}

/** FORK: the intervals.icu description of a breathing session. Twin of the fork iOS `BreathingSessionText`. */
object BreathingSessionText {
    fun description(s: BreathingSession.Summary, exercise: BreathingExercise): String {
        val fr = Locale.getDefault().language == "fr"
        val lines = mutableListOf(exercise.title)
        lines += partLine(if (fr) "Respiration libre" else "Free breathing", s.free)
        lines += partLine(if (fr) "Exercice" else "Exercise", s.guided)
        if (s.holdsSeconds.isNotEmpty()) {
            lines += (if (fr) "Apnées : " else "Breath holds: ") + s.holdsSeconds.joinToString(", ") { "$it s" }
        }
        s.progression?.let { lines += (if (fr) "Niveau " else "Level ") + it.levelBefore }
        s.resonanceBpm?.let { bpm ->
            val pace = "%.1f".format(bpm)
            lines += if (s.resonanceLocked) {
                if (fr) "Rythme de résonance trouvé : $pace respirations/min" else "Resonance pace found: $pace breaths/min"
            } else {
                if (fr) "Rythme de résonance incertain, $pace respirations/min conservé" else "Resonance pace unclear, kept $pace breaths/min"
            }
        }
        lines += if (fr) "La fréquence respiratoire est lue dans le battement du cœur (RSA) ; pendant la respiration guidée, le rythme guidé comble les trous."
        else "Breathing rate is read from the heartbeat (RSA); during guided breathing, the guided pace fills gaps."
        lines += "NOOP"
        return lines.joinToString("\n")
    }

    private fun partLine(name: String, p: BreathingSession.PartStats): String {
        val fr = Locale.getDefault().language == "fr"
        val bits = mutableListOf("$name (${p.seconds / 60} min ${p.seconds % 60} s)")
        p.avgHR?.let { bits += (if (fr) "FC " else "HR ") + "${Math.round(it)} bpm" }
        p.avgBreathsPerMin?.let { bits += (if (fr) "respiration " else "breathing ") + "%.1f/min".format(it) }
        p.rmssd?.let { bits += "RMSSD ${Math.round(it)} ms" }
        p.avgCoherence?.let { bits += (if (fr) "cohérence " else "coherence ") + "${Math.round(it)}/100" }
        return bits.joinToString(" · ")
    }
}
