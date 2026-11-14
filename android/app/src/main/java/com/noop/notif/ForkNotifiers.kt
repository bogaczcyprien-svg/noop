package com.noop.notif

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.analytics.AlarmWakeQuality
import com.noop.analytics.AnalyticsEngine
import com.noop.analytics.Baselines
import com.noop.analytics.BedtimeRecommendation
import com.noop.analytics.EarlyNightRecovery
import com.noop.analytics.HrvTrendStreak
import com.noop.analytics.NightExplainer
import com.noop.analytics.OverloadPolicy
import com.noop.analytics.RestScorer
import com.noop.analytics.SleepDebt
import com.noop.data.DailyMetric
import com.noop.data.WhoopRepository
import com.noop.ui.EffortScale
import com.noop.ui.NoopPrefs
import com.noop.ui.UnitFormatter
import com.noop.ui.appLaunchIntent
import com.noop.ui.optimalStrainRange
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.roundToInt

// FORK: Android twins of the fork iOS local notifications — the morning sleep recap (with bedtime
// suggestion, alarm wake-quality, early-night recovery and night explainer lines), the HRV trend nudge,
// the post-workout nutrition reminder, and the overload alert. All default OFF, all local, no network.

private const val FORK_CHANNEL_ID = "noop_fork_recaps"

@SuppressLint("MissingPermission")
internal fun postForkNotification(ctx: Context, id: Int, title: String, body: String) {
    runCatching {
        if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
                NotificationChannel(FORK_CHANNEL_ID, "Résumés et alertes", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }
        val n = NotificationCompat.Builder(ctx, FORK_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_heart)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(
                PendingIntent.getActivity(ctx, id, appLaunchIntent(ctx),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT),
            )
            .setAutoCancel(true)
            .build()
        NotificationManagerCompat.from(ctx).notify(id, n)
    }
}

private fun prefBool(ctx: Context, key: String) = NoopPrefs.of(ctx).getBoolean(key, false)
private fun setPrefBool(ctx: Context, key: String, on: Boolean) =
    NoopPrefs.of(ctx).edit().putBoolean(key, on).apply()

object SleepRecapNotifier {
    private const val KEY_ENABLED = "noop.sleepRecap.enabled"
    private const val KEY_LAST = "noop.sleepRecap.lastPostedDay"
    private const val NOTIF_ID = 4731

    fun isEnabled(ctx: Context) = prefBool(ctx, KEY_ENABLED)
    fun setEnabled(ctx: Context, on: Boolean) = setPrefBool(ctx, KEY_ENABLED, on)

    suspend fun postIfDue(ctx: Context, repo: WhoopRepository, deviceId: String) {
        if (!isEnabled(ctx)) return
        val sorted = runCatching { repo.daysMerged(deviceId) }.getOrNull()?.sortedBy { it.day }?.takeLast(17) ?: return
        val latest = sorted.lastOrNull { it.totalSleepMin != null } ?: return
        if (NoopPrefs.of(ctx).getString(KEY_LAST, null) == latest.day) return
        if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return

        val lines = mutableListOf(summary(latest))
        bedtimeLine(repo, deviceId, sorted)?.let { lines.add(it) }
        val now = System.currentTimeMillis() / 1000
        val session = runCatching { repo.sleepSessionsMerged(deviceId, now - 2 * 86_400, now, 10) }
            .getOrNull()?.maxByOrNull { it.endTs }
        if (session != null) {
            alarmLine(ctx, session.stagesJSON, session.endTs)?.let { lines.add(it) }
            earlyNightLine(repo, deviceId, session.startTs, session.endTs)?.let { lines.add(it) }
        }
        nightExplainerLine(repo, latest, sorted)?.let { lines.add(it) }

        postForkNotification(ctx, NOTIF_ID, "Votre nuit", lines.joinToString("\n"))
        NoopPrefs.of(ctx).edit().putString(KEY_LAST, latest.day).apply()
    }

    fun summary(m: DailyMetric): String {
        val parts = mutableListOf<String>()
        m.totalSleepMin?.let { parts.add(fmtDuration(it)) }
        m.efficiency?.let { parts.add("${(it * 100).roundToInt()}% efficacité") }
        val phases = mutableListOf<String>()
        m.deepMin?.let { phases.add("profond ${fmtDuration(it)}") }
        m.remMin?.let { phases.add("REM ${fmtDuration(it)}") }
        m.lightMin?.let { phases.add("léger ${fmtDuration(it)}") }
        if (phases.isNotEmpty()) parts.add(phases.joinToString(", "))
        m.recovery?.let { parts.add("Réparation ${it.roundToInt()}%") }
        return if (parts.isEmpty()) "Résumé de la nuit disponible dans NOOP." else parts.joinToString(" — ")
    }

    private suspend fun bedtimeLine(repo: WhoopRepository, deviceId: String, days: List<DailyMetric>): String? {
        val ledger = SleepDebt.ledger(days.map { it.day to it.totalSleepMin })
        if (ledger.nightCount == 0) return null
        val now = System.currentTimeMillis() / 1000
        val sessions = runCatching { repo.sleepSessionsMerged(deviceId, now - 7 * 86_400, now, 20) }.getOrNull()
        if (sessions.isNullOrEmpty()) return null
        val tz = TimeZone.getDefault().getOffset(now * 1000) / 1000
        val wake = sessions.map { (((it.endTs + tz) % 86_400 + 86_400) % 86_400 / 60).toInt() }
        val habitual = wake.sum() / wake.size
        val rec = BedtimeRecommendation.recommend(ledger.balanceMin, RestScorer.defaultSleepNeedHours * 60, habitual)
        val clock = BedtimeRecommendation.formatClock(rec.bedtimeMinutes)
        return if (rec.debtOwedMin > 0)
            "Ce soir, visez un coucher vers $clock (inclut ${rec.debtOwedMin.roundToInt()}min de dette de sommeil)."
        else "Ce soir, visez un coucher vers $clock."
    }

    private fun alarmLine(ctx: Context, stagesJson: String?, endTs: Long): String? {
        if (!NoopPrefs.smartAlarmEnabled(ctx)) return null
        val minutes = NoopPrefs.smartAlarmMinutes(ctx)
        val segs = AnalyticsEngine.decodeStages(stagesJson)
        if (segs.isEmpty()) return null
        val tz = TimeZone.getDefault().getOffset(endTs * 1000) / 1000
        val v = AlarmWakeQuality.stageAtAlarm(segs, endTs, minutes, tz) ?: return null
        val clock = BedtimeRecommendation.formatClock(minutes)
        return when (v) {
            AlarmWakeQuality.Verdict.LIGHT -> "Le réveil ($clock) est tombé en sommeil léger — bon timing."
            AlarmWakeQuality.Verdict.DEEP -> "Le réveil ($clock) est tombé en sommeil profond — pas le moment idéal."
            AlarmWakeQuality.Verdict.REM -> "Le réveil ($clock) est tombé en sommeil paradoxal — pas le moment idéal."
            else -> null
        }
    }

    private suspend fun earlyNightLine(repo: WhoopRepository, deviceId: String, start: Long, end: Long): String? {
        val all = runCatching { repo.rrIntervalsUnion(deviceId, start, end, 20_000) }.getOrNull() ?: return null
        val earlyEnd = start + EarlyNightRecovery.EARLY_WINDOW_MINUTES * 60
        val r = EarlyNightRecovery.evaluate(
            all.filter { it.ts <= earlyEnd }.map { it.rrMs.toDouble() },
            all.map { it.rrMs.toDouble() },
        ) ?: return null
        return "Récupération en début de nuit : ${(r.ratio * 100).roundToInt()}% de votre moyenne de la nuit."
    }

    private val negativeFactors = setOf(
        "Did you drink any alcohol?", "Did you have caffeine late in the day?",
        "Did you view a screen in bed?", "Did you eat close to bedtime?",
        "Did you feel stressed?", "Did you feel sick or ill?",
    )

    private suspend fun nightExplainerLine(repo: WhoopRepository, latest: DailyMetric, days: List<DailyMetric>): String? {
        val recovery = latest.recovery ?: return null
        if (recovery >= 50) return null
        val day = latest.day
        val entries = listOf("noop-journal", WhoopRepository.WHOOP_SOURCE).flatMap {
            runCatching { repo.journal(it, day, day) }.getOrDefault(emptyList())
        }
        val logged = entries.filter { it.answeredYes && it.question in negativeFactors }.map { it.question }.distinct()
        val prior = days.filter { it.day < day }
        val hrvB = Baselines.foldHistory(prior.map { it.avgHrv }, Baselines.hrvCfg)
        val hrvZ = latest.avgHrv?.let { if (hrvB.usable) Baselines.deviation(it, hrvB).z else null }
        val rhrB = Baselines.foldHistory(prior.map { it.restingHr?.toDouble() }, Baselines.restingHRCfg)
        val rhrZ = latest.restingHr?.let { if (rhrB.usable) -Baselines.deviation(it.toDouble(), rhrB).z else null }
        return NightExplainer.explain(logged, hrvZ, rhrZ)
    }

    private fun fmtDuration(min: Double): String {
        val t = min.roundToInt()
        val h = t / 60
        val m = t % 60
        return if (h > 0) "${h}h${m.toString().padStart(2, '0')}" else "${m}min"
    }
}

object TrendNotifier {
    private const val KEY_ENABLED = "noop.trendNotifier.enabled"
    private const val KEY_LAST = "noop.trendNotifier.lastNotifiedDay"
    private const val NOTIF_ID = 4732

    fun isEnabled(ctx: Context) = prefBool(ctx, KEY_ENABLED)
    fun setEnabled(ctx: Context, on: Boolean) = setPrefBool(ctx, KEY_ENABLED, on)

    suspend fun postIfDue(ctx: Context, repo: WhoopRepository, deviceId: String) {
        if (!isEnabled(ctx)) return
        val sorted = runCatching { repo.daysMerged(deviceId) }.getOrNull()?.sortedBy { it.day }?.takeLast(46) ?: return
        val latestDay = sorted.lastOrNull { it.avgHrv != null }?.day ?: return
        if (NoopPrefs.of(ctx).getString(KEY_LAST, null) == latestDay) return
        val streak = HrvTrendStreak.currentStreak(sorted.map { it.avgHrv }) ?: return
        if (streak.count < HrvTrendStreak.MIN_STREAK_NIGHTS) return
        if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return
        val direction = if (streak.aboveBaseline) "au-dessus" else "en-dessous"
        val pct = (abs(streak.avgRatio) * 100).roundToInt()
        postForkNotification(ctx, NOTIF_ID, "Tendance inhabituelle",
            "Votre HRV est ~$pct% $direction de d'habitude depuis ${streak.count} nuits.")
        NoopPrefs.of(ctx).edit().putString(KEY_LAST, latestDay).apply()
    }
}

object WorkoutNutritionNotifier {
    private const val KEY_ENABLED = "noop.workoutNutrition.enabled"
    private const val KEY_LAST = "noop.workoutNutrition.lastNotifiedEndTs"
    private const val NOTIF_ID = 4733
    const val RECENCY_WINDOW_MIN = 90

    fun isEnabled(ctx: Context) = prefBool(ctx, KEY_ENABLED)
    fun setEnabled(ctx: Context, on: Boolean) = setPrefBool(ctx, KEY_ENABLED, on)

    suspend fun postIfDue(ctx: Context, repo: WhoopRepository, deviceId: String) {
        if (!isEnabled(ctx)) return
        val now = System.currentTimeMillis() / 1000
        val ids = listOf(deviceId, "intervals-icu").distinct()
        val latest = ids.flatMap { runCatching { repo.workouts(it, now - 2 * 86_400, now, 10) }.getOrDefault(emptyList()) }
            .maxByOrNull { it.endTs } ?: return
        if (now - latest.endTs > RECENCY_WINDOW_MIN * 60) return
        if (NoopPrefs.of(ctx).getLong(KEY_LAST, 0L) == latest.endTs) return
        if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return
        postForkNotification(ctx, NOTIF_ID, "Après l'effort",
            "Séance terminée — pensez à manger et à vous hydrater dans l'heure qui suit.")
        NoopPrefs.of(ctx).edit().putLong(KEY_LAST, latest.endTs).apply()
    }
}

object OverloadNotifier {
    private const val KEY_ENABLED = "behavior.overloadAlert"
    private const val KEY_LAST = "behavior.overloadLastDay"
    private const val NOTIF_ID = 4734

    fun isEnabled(ctx: Context) = prefBool(ctx, KEY_ENABLED)
    fun setEnabled(ctx: Context, on: Boolean) = setPrefBool(ctx, KEY_ENABLED, on)

    fun onDaysUpdate(ctx: Context, today: String, days: List<DailyMetric>) {
        val rows = days.map {
            OverloadPolicy.Day(
                it.day,
                it.strain?.let { s -> UnitFormatter.effortValue(s, EffortScale.WHOOP) },
                optimalStrainRange(it.recovery)?.high,
            )
        }
        val streak = OverloadPolicy.currentStreak(rows)
        if (!OverloadPolicy.shouldNotify(isEnabled(ctx), streak, NoopPrefs.of(ctx).getString(KEY_LAST, null), today)) return
        if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return
        postForkNotification(ctx, NOTIF_ID, "Charge d'entraînement élevée",
            "Ton effort est au-dessus de ta zone optimale depuis $streak jours de suite. Une journée plus facile laisserait la récupération rattraper.")
        NoopPrefs.of(ctx).edit().putString(KEY_LAST, today).apply()
    }
}
