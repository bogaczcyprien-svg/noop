package com.noop.breathing

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.noop.R
import com.noop.analytics.BedtimeBreathingGate
import com.noop.data.WhoopRepository
import com.noop.ui.NoopPrefs
import com.noop.ui.appLaunchIntent
import java.time.LocalDate
import java.time.LocalTime
import java.util.Locale

/**
 * FORK: once per evening, between 21:00 and 23:00, suggests cardiac coherence when the strap sees the
 * wearer lying still but still awake. Twin of the fork iOS `BedtimeBreathingNudge`. Off by default.
 */
object BedtimeBreathingNudge {
    private const val KEY_ENABLED = "noop.breathing.bedtimeNudge"
    private const val KEY_LAST_DAY = "noop.breathing.bedtimeNudge.lastDay"
    private const val CHANNEL_ID = "noop_bedtime_breathing"
    private const val NOTIF_ID = 4721

    fun isEnabled(ctx: Context): Boolean = NoopPrefs.of(ctx).getBoolean(KEY_ENABLED, false)
    fun setEnabled(ctx: Context, on: Boolean) { NoopPrefs.of(ctx).edit().putBoolean(KEY_ENABLED, on).apply() }

    /** A session done this evening counts as answered: no reminder afterwards. */
    fun noteSessionDone(ctx: Context) {
        NoopPrefs.of(ctx).edit().putString(KEY_LAST_DAY, LocalDate.now().toString()).apply()
    }

    suspend fun postIfDue(ctx: Context, repo: WhoopRepository, deviceId: String) {
        if (!isEnabled(ctx)) return
        val today = LocalDate.now().toString()
        if (NoopPrefs.of(ctx).getString(KEY_LAST_DAY, null) == today) return
        val now = System.currentTimeMillis() / 1000
        val t = LocalTime.now()
        val minute = t.hour * 60 + t.minute
        if (minute !in BedtimeBreathingGate.WINDOW_MINUTES) return
        val from = now - BedtimeBreathingGate.LOOKBACK_SECONDS
        val hr = runCatching { repo.hrSamplesUnion(deviceId, from, now) }.getOrDefault(emptyList())
        val grav = runCatching { repo.gravitySamplesUnion(deviceId, from, now, 20_000) }.getOrDefault(emptyList())
        val resting = runCatching { repo.daysMerged(deviceId).maxByOrNull { it.day }?.restingHr?.toDouble() }.getOrNull()
        if (BedtimeBreathingGate.evaluate(now, minute, hr, grav, resting) != BedtimeBreathingGate.Verdict.NUDGE) return
        post(ctx)
        NoopPrefs.of(ctx).edit().putString(KEY_LAST_DAY, today).apply()
    }

    @SuppressLint("MissingPermission")
    private fun post(ctx: Context) {
        runCatching {
            if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return
            val fr = Locale.getDefault().language == "fr"
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager).createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, if (fr) "Respiration au coucher" else "Bedtime breathing",
                        NotificationManager.IMPORTANCE_DEFAULT),
                )
            }
            val n = NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_stat_heart)
                .setContentTitle(if (fr) "C'est le moment de respirer" else "Time to breathe")
                .setContentText(
                    if (fr) "Tu as l'air installé au lit. Cinq minutes de cohérence cardiaque aident à s'endormir."
                    else "You look settled in bed. Five minutes of cardiac coherence helps you fall asleep.",
                )
                .setContentIntent(PendingIntent.getActivity(ctx, 9, appLaunchIntent(ctx),
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
                .setAutoCancel(true)
                .build()
            NotificationManagerCompat.from(ctx).notify(NOTIF_ID, n)
        }
    }
}
