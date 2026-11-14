package com.noop.intervals

import android.content.Context
import com.noop.data.WhoopRepository
import com.noop.ui.ProfileStore

/**
 * FORK: sends the latest scored night to intervals.icu wellness (HRV, resting HR, sleep, NOOP's own
 * Charge as "readiness", weight, steps), each field behind its own toggle. Twin of the fork iOS
 * `IntervalsICUWellnessPush`. Off until the user enables it.
 */
object IntervalsIcuWellnessPush {
    sealed class Outcome {
        data class Pushed(val day: String) : Outcome()
        data object Disabled : Outcome()
        data object NoApiKey : Outcome()
        data object NothingToPush : Outcome()
    }

    suspend fun pushLatestNight(ctx: Context, repo: WhoopRepository, deviceId: String): Outcome {
        if (!IntervalsIcuSettings.pushEnabled(ctx)) return Outcome.Disabled
        val client = IntervalsIcuSettings.client(ctx) ?: return Outcome.NoApiKey
        val fields = IntervalsIcuSettings.pushFields(ctx)
        val from = IntervalsIcuDates.daysAgo(2)
        val latest = repo.daysMerged(deviceId)
            .filter { it.day >= from && it.totalSleepMin != null }
            .maxByOrNull { it.day } ?: return Outcome.NothingToPush

        val sleep = IntervalsIcuSettings.WellnessField.SLEEP in fields
        client.putWellness(
            date = latest.day,
            hrv = if (IntervalsIcuSettings.WellnessField.HRV in fields) latest.avgHrv else null,
            restingHR = if (IntervalsIcuSettings.WellnessField.RESTING_HR in fields) latest.restingHr else null,
            readiness = if (IntervalsIcuSettings.WellnessField.CHARGE in fields) latest.recovery else null,
            sleepSecs = if (sleep) latest.totalSleepMin?.let { Math.round(it * 60).toInt() } else null,
            sleepScore = if (sleep) latest.efficiency?.let { Math.round(it * 100).toInt() } else null,
            weightKg = if (IntervalsIcuSettings.WellnessField.WEIGHT in fields) ProfileStore.from(ctx).weightKg else null,
            steps = if (IntervalsIcuSettings.WellnessField.STEPS in fields) latest.steps else null,
        )
        return Outcome.Pushed(latest.day)
    }
}
