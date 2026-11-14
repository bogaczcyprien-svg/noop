package com.noop.intervals

import android.content.Context
import com.noop.data.HrSample
import com.noop.data.WhoopRepository
import com.noop.data.WorkoutRow
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter

/** FORK: day keys in the yyyy-MM-dd shape intervals.icu expects. */
object IntervalsIcuDates {
    private val day = DateTimeFormatter.ofPattern("yyyy-MM-dd")
    fun today(): String = LocalDate.now().format(day)
    fun daysAgo(n: Long): String = LocalDate.now().minusDays(n).format(day)
    fun inDays(n: Long): String = LocalDate.now().plusDays(n).format(day)

    /** `start_date_local` ("2026-11-13T18:30:00") read on the device's own clock, as unix seconds. */
    fun localToEpoch(local: String?): Long? = runCatching {
        LocalDateTime.parse(local!!.take(19)).atZone(ZoneId.systemDefault()).toEpochSecond()
    }.getOrNull()
}

/**
 * FORK: pulls intervals.icu activities into NOOP. Twin of the fork iOS `IntervalsICUImporter`:
 * - each activity becomes a workout row under [DEVICE_ID] (its own calories, distance, HR summary);
 * - its real heart-rate stream (or a flat line at its average HR when there is no stream) is written as
 *   HR samples, so Effort and the day's heart-rate charts include the session;
 * - pairs created by an older UTC parse of `start_date_local` are removed.
 * NOOP never borrows intervals.icu's own strain: it scores the session from the heart rate itself.
 */
object IntervalsIcuImporter {
    const val DEVICE_ID = "intervals-icu"

    suspend fun importRecent(ctx: Context, repo: WhoopRepository, days: Long = 30): Int {
        val client = IntervalsIcuSettings.client(ctx) ?: throw IntervalsIcuHttpException(401)
        val activities = client.activities(IntervalsIcuDates.daysAgo(days), IntervalsIcuDates.today())
        val rows = activities.mapNotNull(::toWorkoutRow)
        repo.upsertWorkouts(rows)
        backfillHr(activities, client, repo)
        deduplicateTimezoneArtifacts(repo)
        return rows.size
    }

    private suspend fun deduplicateTimezoneArtifacts(repo: WhoopRepository) {
        val farFuture = System.currentTimeMillis() / 1000 + 86_400
        val rows = runCatching { repo.workouts(DEVICE_ID, 0, farFuture, 5000) }.getOrNull() ?: return
        if (rows.size < 2) return
        val consumed = HashSet<Int>()
        val toDelete = ArrayList<WorkoutRow>()
        for (i in rows.indices) {
            if (i in consumed) continue
            for (j in i + 1 until rows.size) {
                if (j in consumed) continue
                val a = rows[i]
                val b = rows[j]
                if (a.sport != b.sport || a.startTs == b.startTs || a.durationS != b.durationS ||
                    a.avgHr != b.avgHr || a.maxHr != b.maxHr || a.distanceM != b.distanceM ||
                    a.energyKcal != b.energyKcal || a.notes != b.notes
                ) continue
                when {
                    isUtcMislabeledPair(a.startTs, b.startTs) -> toDelete.add(a)
                    isUtcMislabeledPair(b.startTs, a.startTs) -> toDelete.add(b)
                    else -> continue
                }
                consumed.add(i); consumed.add(j)
                break
            }
        }
        for (row in toDelete) runCatching { repo.deleteWorkout(row) }
    }

    private fun isUtcMislabeledPair(oldCandidateTs: Long, newCandidateTs: Long): Boolean {
        val offset = ZoneId.systemDefault().rules
            .getOffset(java.time.Instant.ofEpochSecond(newCandidateTs)).totalSeconds
        return oldCandidateTs - newCandidateTs == offset.toLong()
    }

    private suspend fun backfillHr(activities: List<IntervalsIcuActivity>, client: IntervalsIcuClient, repo: WhoopRepository) {
        for (a in activities) {
            val startTs = IntervalsIcuDates.localToEpoch(a.startDateLocal) ?: continue
            val duration = a.movingTime ?: a.elapsedTime ?: 0
            if (duration <= 0) continue
            val real = runCatching { client.streams(a.id, listOf("time", "heartrate")) }.getOrNull()
                ?.let { realHrRows(it, startTs) }
            if (!real.isNullOrEmpty()) {
                insert(real, repo)
            } else if (a.averageHeartrate != null) {
                insert(flatHrRows(startTs, duration, Math.round(a.averageHeartrate).toInt()), repo)
            }
        }
    }

    internal fun realHrRows(streams: List<IntervalsIcuStream>, activityStartTs: Long): List<Pair<Long, Int>>? {
        val time = streams.firstOrNull { it.type == "time" }?.data ?: return null
        val hr = streams.firstOrNull { it.type == "heartrate" }?.data ?: return null
        if (time.isEmpty() || hr.isEmpty()) return null
        val rows = ArrayList<Pair<Long, Int>>(minOf(time.size, hr.size))
        for (i in 0 until minOf(time.size, hr.size)) {
            val offset = time[i] ?: continue
            val bpm = hr[i] ?: continue
            if (bpm <= 0) continue
            rows.add((activityStartTs + Math.round(offset)) to Math.round(bpm).toInt())
        }
        return rows
    }

    private fun flatHrRows(startTs: Long, duration: Int, bpm: Int): List<Pair<Long, Int>> {
        val rows = ArrayList<Pair<Long, Int>>()
        var t = startTs
        while (t <= startTs + duration) {
            rows.add(t to bpm)
            t += 60
        }
        return rows
    }

    private suspend fun insert(rows: List<Pair<Long, Int>>, repo: WhoopRepository) {
        if (rows.isEmpty()) return
        runCatching { repo.insertHr(rows.map { HrSample(WhoopRepository.WHOOP_SOURCE, it.first, it.second) }) }
    }

    private fun toWorkoutRow(a: IntervalsIcuActivity): WorkoutRow? {
        val startTs = IntervalsIcuDates.localToEpoch(a.startDateLocal) ?: return null
        val duration = a.movingTime ?: a.elapsedTime ?: 0
        return WorkoutRow(
            deviceId = DEVICE_ID,
            startTs = startTs,
            endTs = startTs + duration,
            sport = a.type ?: "Workout",
            source = "intervals.icu",
            durationS = if (duration > 0) duration.toDouble() else null,
            energyKcal = a.calories,
            avgHr = a.averageHeartrate?.let { Math.round(it).toInt() },
            maxHr = a.maxHeartrate?.let { Math.round(it).toInt() },
            strain = null,
            distanceM = a.distance,
            zonesJSON = null,
            notes = a.name,
            steps = null,
        )
    }
}
