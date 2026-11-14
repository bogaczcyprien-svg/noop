package com.noop.intervals

import android.content.Context
import com.noop.data.WhoopRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * FORK: runs the intervals.icu pull and wellness push and keeps their last outcome for Settings. Twin
 * of the fork iOS `IntervalsICURunner`. [afterOffload] is wired to the end of every strap sync, like
 * the iOS post-offload hook; both halves no-op until the user configures intervals.icu.
 */
object IntervalsIcuRunner {
    private val lock = Mutex()
    private val _running = MutableStateFlow(false)
    val running: StateFlow<Boolean> = _running
    private val _lastResult = MutableStateFlow<String?>(null)
    val lastResult: StateFlow<String?> = _lastResult
    private val _lastPushResult = MutableStateFlow<String?>(null)
    val lastPushResult: StateFlow<String?> = _lastPushResult

    /** Bumped after every successful import so screens listing activities can reload. */
    private val _revision = MutableStateFlow(0)
    val revision: StateFlow<Int> = _revision

    suspend fun importRecent(ctx: Context, repo: WhoopRepository, days: Long = 30) {
        if (!lock.tryLock()) return
        try {
            _running.value = true
            val count = IntervalsIcuImporter.importRecent(ctx, repo, days)
            _lastResult.value = "$count séance(s) importée(s)"
            _revision.value += 1
        } catch (e: IntervalsIcuHttpException) {
            _lastResult.value = if (e.code == 401) "Clé API manquante ou refusée" else "Échec : HTTP ${e.code}"
        } catch (e: Exception) {
            _lastResult.value = "Échec : ${e.message ?: e.javaClass.simpleName}"
        } finally {
            _running.value = false
            lock.unlock()
        }
    }

    suspend fun pushLastNightIfEnabled(ctx: Context, repo: WhoopRepository, deviceId: String) {
        try {
            when (val o = IntervalsIcuWellnessPush.pushLatestNight(ctx, repo, deviceId)) {
                is IntervalsIcuWellnessPush.Outcome.Pushed -> _lastPushResult.value = "Envoyé pour le ${o.day}"
                IntervalsIcuWellnessPush.Outcome.Disabled -> Unit
                IntervalsIcuWellnessPush.Outcome.NoApiKey -> _lastPushResult.value = "Clé API manquante"
                IntervalsIcuWellnessPush.Outcome.NothingToPush ->
                    _lastPushResult.value = "Aucune nuit récente avec des données de sommeil à envoyer"
            }
        } catch (e: Exception) {
            _lastPushResult.value = "Échec : ${e.message ?: e.javaClass.simpleName}"
        }
    }

    /** Post-sync hook: push the night, then pull new activities. Both no-op without an API key. */
    suspend fun afterOffload(ctx: Context, repo: WhoopRepository, deviceId: String) {
        if (!IntervalsIcuSettings.hasApiKey(ctx)) return
        lock.withLock { } // wait for a manual import already running instead of racing it
        pushLastNightIfEnabled(ctx, repo, deviceId)
        importRecent(ctx, repo)
    }
}
