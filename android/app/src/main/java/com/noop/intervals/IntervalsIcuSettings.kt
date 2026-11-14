package com.noop.intervals

import android.content.Context
import android.content.SharedPreferences
import com.noop.data.SecurePrefs
import com.noop.ui.NoopPrefs

/**
 * FORK: intervals.icu connection settings. Twin of the fork iOS `IntervalsICUSettings`: the athlete id
 * and toggles live in the ordinary prefs, the API key in the encrypted prefs file.
 *
 * The connection is opt-in and only talks to intervals.icu, an account the user owns and configures.
 */
object IntervalsIcuSettings {
    private const val KEY_ATHLETE_ID = "noop.intervalsicu.athleteId"
    private const val KEY_PUSH_ENABLED = "noop.intervalsicu.pushEnabled"
    private const val SECURE_FILE = "noop_intervals_secure_prefs"
    private const val KEY_API = "apiKey"

    /** Wellness fields the push can send, each with its own toggle (default ON once push is enabled). */
    enum class WellnessField(val raw: String) {
        HRV("hrv"), RESTING_HR("restingHR"), SLEEP("sleep"), WEIGHT("weight"), STEPS("steps"), CHARGE("charge");

        internal val key: String get() = "noop.intervalsicu.push.$raw"
    }

    private fun prefs(ctx: Context): SharedPreferences = NoopPrefs.of(ctx)
    private fun secure(ctx: Context): SharedPreferences = SecurePrefs.of(ctx, SECURE_FILE)

    /** "0" means "the athlete the API key belongs to", which is what intervals.icu accepts. */
    fun athleteId(ctx: Context): String =
        prefs(ctx).getString(KEY_ATHLETE_ID, null)?.trim()?.takeIf { it.isNotEmpty() } ?: "0"

    fun setAthleteId(ctx: Context, id: String) {
        prefs(ctx).edit().putString(KEY_ATHLETE_ID, id.trim()).apply()
    }

    fun apiKey(ctx: Context): String? =
        runCatching { secure(ctx).getString(KEY_API, null) }.getOrNull()?.takeIf { it.isNotBlank() }

    fun hasApiKey(ctx: Context): Boolean = apiKey(ctx) != null

    fun setApiKey(ctx: Context, key: String) {
        val trimmed = key.trim()
        runCatching {
            if (trimmed.isEmpty()) secure(ctx).edit().remove(KEY_API).apply()
            else secure(ctx).edit().putString(KEY_API, trimmed).apply()
        }
    }

    fun pushEnabled(ctx: Context): Boolean = prefs(ctx).getBoolean(KEY_PUSH_ENABLED, false)

    fun setPushEnabled(ctx: Context, enabled: Boolean) {
        prefs(ctx).edit().putBoolean(KEY_PUSH_ENABLED, enabled).apply()
    }

    fun pushField(ctx: Context, field: WellnessField): Boolean = prefs(ctx).getBoolean(field.key, true)

    fun setPushField(ctx: Context, field: WellnessField, enabled: Boolean) {
        prefs(ctx).edit().putBoolean(field.key, enabled).apply()
    }

    fun pushFields(ctx: Context): Set<WellnessField> =
        WellnessField.entries.filter { pushField(ctx, it) }.toSet()

    /** A client for the configured account, or null when no API key is set. */
    fun client(ctx: Context): IntervalsIcuClient? =
        apiKey(ctx)?.let { IntervalsIcuClient(athleteId(ctx), it) }
}
