package com.noop.analytics

import com.noop.data.GravitySample
import com.noop.data.HrSample
import com.noop.data.RrInterval
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Lead-in cardiac wake for V2 (on by default) ([SleepStagerV2.leadInCardiacWakeEnd]). Android twin of the Swift
 * `LeadInCardiacWakeTests`. The quiescent cardiac clamp holds a motionless, elevated-HR epoch out of wake all
 * night, which also credits lying still AWAKE before sleep as sleep, so onset reads early. With the flag on,
 * the clamp is lifted for the pre-sleep lead-in only. These pin: the pre-rule path (`false`) still reads early, a still awake
 * lead-in moves onset later, the lift stops at sleep onset (a mid-night still elevated-HR stretch keeps the
 * clamp), and the lift is capped at [SleepStagerV2.leadInCardiacWakeMaxMinutes].
 */
class LeadInCardiacWakeTest {

    private val dev = "test"
    private val start = 1_749_517_200L

    // ── fixtures ───────────────────────────────────────────────────────────────────────────────────────

    /** Still gravity at 1 Hz for the whole window: the wrist never moves, so every epoch is quiescent. */
    private fun stillGravity(durationS: Int): List<GravitySample> =
        (0 until durationS).map { GravitySample(deviceId = dev, ts = start + it, x = 0.0, y = 0.0, z = 1.0) }

    /** Awake-but-still HR (66-72 bpm, stepping every 7 s) over [awakeSpans], sleep-band HR (52-54) elsewhere. */
    private fun hr(durationS: Int, awakeSpans: List<IntRange>): List<HrSample> =
        (0 until durationS).map { i ->
            val awake = awakeSpans.any { i in it }
            HrSample(deviceId = dev, ts = start + i, bpm = if (awake) 66 + (i / 7) % 7 else 52 + (i / 60) % 3)
        }

    /** Regular R-R with a small respiratory oscillation, shorter beats while awake. */
    private fun rr(durationS: Int, awakeSpans: List<IntRange>): List<RrInterval> =
        (0 until durationS).map { i ->
            val mean = if (awakeSpans.any { i in it }) 880 else 1130
            val rsa = (40.0 * sin(2.0 * PI * i / 4.0)).roundToInt()
            RrInterval(deviceId = dev, ts = start + i, rrMs = mean + rsa)
        }

    private fun stage(durationS: Int, awakeSpans: List<IntRange>, leadIn: Boolean): List<StageSegment> =
        SleepStagerV2.stageSession(
            start = start, end = start + durationS, grav = stillGravity(durationS),
            hr = hr(durationS, awakeSpans), rr = rr(durationS, awakeSpans), resp = emptyList(),
            leadInCardiacWake = leadIn,
        )

    /** Minutes from the window start to the first non-wake run of at least 5 minutes (the PSG onset rule). */
    private fun onsetMinutes(segs: List<StageSegment>): Double? {
        var i = 0
        while (i < segs.size) {
            if (segs[i].stage == "wake") { i++; continue }
            val runStart = segs[i].start
            var runEnd = segs[i].end
            var j = i + 1
            while (j < segs.size && segs[j].stage != "wake") { runEnd = segs[j].end; j++ }
            if (runEnd - runStart >= 300) return (runStart - start) / 60.0
            i = j
        }
        return null
    }

    private fun wakeMinutesIn(segs: List<StageSegment>, from: Int, to: Int): Double =
        segs.filter { it.stage == "wake" }.sumOf { s ->
            val lo = maxOf(s.start, start + from); val hi = minOf(s.end, start + to)
            maxOf(0L, hi - lo).toDouble()
        } / 60.0

    // ── the rule in isolation ─────────────────────────────────────────────────────────────────────────

    private fun epoch(i: Int) = SleepStagerV2.Epoch(
        start = start + 30L * i, hr = 52.0, hrVar = 1.0, hrFlat11 = 1.0, moveFrac = 0.0, jerkMax = 0.001,
        respReg = null, clock = 0.0, jerkScale = 0.001, minutesSinceOnset = i * 0.5 + 0.25,
    )

    @Test
    fun leadInEndStopsAtTheOpenPassOnset() {
        val feats = (0 until 400).map(::epoch)
        // 40 awake epochs (20 min) then sustained sleep: everything before the onset is lifted.
        val labels = List(40) { "awake" } + List(360) { "light" }
        assertEquals(40, SleepStagerV2.leadInCardiacWakeEnd(feats, labels))
    }

    @Test
    fun leadInEndIsZeroWhenTheOpenPassNeverSustainsSleepOrSleepsAtOnce() {
        val feats = (0 until 100).map(::epoch)
        assertEquals(0, SleepStagerV2.leadInCardiacWakeEnd(feats, List(100) { "awake" }))
        // A non-wake run shorter than the 5-minute rule is not an onset.
        assertEquals(0, SleepStagerV2.leadInCardiacWakeEnd(feats, List(9) { "light" } + List(91) { "awake" }))
        assertEquals(0, SleepStagerV2.leadInCardiacWakeEnd(feats, List(100) { "light" }))
    }

    @Test
    fun leadInEndIsCappedAtNinetyMinutes() {
        val feats = (0 until 600).map(::epoch)
        // Open-pass onset at epoch 300 (150 min): the lift stops at the last epoch centred within 90 min.
        val labels = List(300) { "awake" } + List(300) { "light" }
        assertEquals(180, SleepStagerV2.leadInCardiacWakeEnd(feats, labels))
    }

    // ── end to end through stageSession ───────────────────────────────────────────────────────────────

    /** The reported shape: 40 minutes lying still awake, then a night of sleep. Off, the clamp credits the
     *  lead-in as sleep; on, onset moves to where the heart rate actually settled. */
    @Test
    fun stillAwakeLeadInMovesOnsetLaterOnlyWhenEnabled() {
        val dur = 8 * 60 * 60
        val awake = listOf(0 until 40 * 60)
        val off = onsetMinutes(stage(dur, awake, leadIn = false))
        val on = onsetMinutes(stage(dur, awake, leadIn = true))
        assertNotNull(off); assertNotNull(on)
        assertTrue("off path should still read the still lead-in as sleep (got $off min)", off!! < 10.0)
        assertTrue("on path should place onset near the 40-min settle point (got $on min)", on!! in 30.0..50.0)
    }

    /** A night asleep from the window start stages byte-identically with the flag on, even with a still
     *  elevated-HR stretch mid-night: the lift ends at sleep onset, so the clamp still holds there. */
    @Test
    fun nightAsleepFromTheStartIsUnchangedEvenWithAMidNightElevatedStretch() {
        val dur = 7 * 60 * 60
        val awake = listOf((4 * 60 * 60) until (4 * 60 * 60 + 40 * 60))
        val off = stage(dur, awake, leadIn = false)
        val on = stage(dur, awake, leadIn = true)
        assertEquals(off, on)
        assertTrue(wakeMinutesIn(on, 4 * 60 * 60, 4 * 60 * 60 + 40 * 60) < 5.0)
    }

    /** A lead-in longer than the cap: only its first 90 minutes can be re-read as wake. */
    @Test
    fun liftIsBoundedByTheCapOnALongElevatedLeadIn() {
        val dur = 9 * 60 * 60
        val awake = listOf(0 until 150 * 60)
        val on = onsetMinutes(stage(dur, awake, leadIn = true))
        assertNotNull(on)
        assertTrue("onset must not move past the 90-min cap (got $on min)", on!! in 80.0..100.0)
    }
}
