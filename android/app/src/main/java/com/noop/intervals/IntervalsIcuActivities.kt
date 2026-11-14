package com.noop.intervals

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsBike
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material.icons.filled.Pool
import androidx.compose.material.icons.filled.SelfImprovement
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.ai.AiCoach
import com.noop.ai.AiKeyStore
import com.noop.ai.ChatMsg
import com.noop.analytics.StrainScorer
import com.noop.data.HrSample
import com.noop.data.WorkoutRow
import com.noop.ui.AppViewModel
import com.noop.ui.NoopCard
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ProfileStore
import com.noop.ui.ScreenScaffold
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** FORK: the AI debrief prompt for one session. Twin of the fork Swift `WorkoutDebrief`. */
object WorkoutDebrief {
    private val bands = listOf(
        90.0 to "Z5 anaérobie (90-100%+ RFC)",
        80.0 to "Z4 seuil (80-90% RFC)",
        70.0 to "Z3 aérobie soutenu (70-80% RFC)",
        60.0 to "Z2 aérobie (60-70% RFC)",
        50.0 to "Z1 facile (50-60% RFC)",
    )
    private const val BELOW = "< Z1 (sous 50% RFC)"

    fun zoneBreakdown(hr: List<HrSample>, restingHR: Double, maxHR: Double): List<Pair<String, Double>>? {
        if (hr.isEmpty() || maxHR <= restingHR) return null
        val reserve = maxHR - restingHR
        val counts = HashMap<String, Int>()
        for (s in hr) {
            val pct = (s.bpm - restingHR) / reserve * 100
            val label = bands.firstOrNull { pct >= it.first }?.second ?: BELOW
            counts[label] = (counts[label] ?: 0) + 1
        }
        val total = hr.size.toDouble()
        return (bands.map { it.second } + BELOW).mapNotNull { label ->
            counts[label]?.takeIf { it > 0 }?.let { label to it / total * 100 }
        }
    }

    fun prompt(activity: WorkoutRow, zones: List<Pair<String, Double>>?): String {
        val lines = mutableListOf("Voici une séance que je viens de terminer :")
        lines += "- Sport : ${activity.sport}"
        activity.durationS?.let { lines += "- Durée : ${(it / 60).toInt()} min" }
        activity.distanceM?.let { lines += "- Distance : ${"%.1f".format(Locale.FRANCE, it / 1_000)} km" }
        activity.avgHr?.let { lines += "- FC moyenne : $it bpm" }
        activity.maxHr?.let { lines += "- FC max : $it bpm" }
        activity.energyKcal?.let { lines += "- Calories : ${Math.round(it)} kcal" }
        if (!zones.isNullOrEmpty()) {
            lines += "- Répartition du temps par zone (% réserve de FC, Karvonen) :"
            for ((label, pct) in zones) lines += "  • $label : ${"%.0f".format(pct)}%"
        } else {
            lines += "- (Pas de trace FC détaillée disponible, seulement la FC moyenne/max ci-dessus.)"
        }
        lines += ""
        lines += "Débrief cette séance : explique la part aérobie vs anaérobie de l'effort, ce que ça dit de " +
            "l'intensité réelle par rapport à ce que je visais, et donne-moi un conseil concret pour la " +
            "prochaine sortie. Réponds en français, de façon concise."
        return lines.joinToString("\n")
    }

    suspend fun run(ctx: Context, vm: AppViewModel, activity: WorkoutRow): String {
        val hr = vm.repo.hrSamplesUnion(vm.activeStrapId, activity.startTs, activity.endTs)
        val age = ProfileStore.from(ctx).age
        val maxHr = if (age > 0) StrainScorer.tanakaHRmax(age.toDouble()) else null
        val zones = maxHr?.let { zoneBreakdown(hr, StrainScorer.defaultRestingHR, it) }
        val provider = AiKeyStore.readProvider(ctx)
        val coach = AiCoach(vm.repo, activeStrapId = { vm.activeStrapId })
        return coach.chat(
            ctx,
            history = listOf(ChatMsg(role = "user", text = prompt(activity, zones))),
            provider = provider,
            model = AiKeyStore.readModel(ctx, provider),
            consent = false,
            customBaseUrl = AiKeyStore.readCustomBaseUrl(ctx),
            customAuthHeader = AiKeyStore.readCustomAuthHeader(ctx),
        )
    }
}

/**
 * FORK: the intervals.icu activities list — on Today with [limit] = 2 plus a "see all" row, or the full
 * list on its own screen. Twin of the fork iOS `IntervalsICUActivitiesSection`.
 */
@Composable
fun IntervalsIcuActivitiesSection(vm: AppViewModel, limit: Int? = null, onSeeAll: () -> Unit = {}) {
    val context = LocalContext.current
    val revision by IntervalsIcuRunner.revision.collectAsState()
    var activities by remember { mutableStateOf<List<WorkoutRow>?>(null) }
    LaunchedEffect(revision) {
        val now = System.currentTimeMillis() / 1000
        activities = runCatching {
            vm.repo.workouts(IntervalsIcuImporter.DEVICE_ID, now - 365L * 86_400, now + 86_400, 2000)
        }.getOrDefault(emptyList()).sortedByDescending { it.startTs }
    }
    if (!IntervalsIcuSettings.hasApiKey(context) && activities.isNullOrEmpty()) return

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("INTERVALS.ICU", style = NoopType.caption, color = Palette.textTertiary)
        Text("Activités intervals.icu", style = NoopType.headline, color = Palette.textPrimary)
        val list = activities
        when {
            list == null -> NoopCard { Text("Chargement…", style = NoopType.body, color = Palette.textTertiary) }
            list.isEmpty() -> NoopCard {
                Text(
                    "Aucune activité importée pour l'instant. Utilisez « Importer maintenant » dans les réglages intervals.icu.",
                    style = NoopType.body, color = Palette.textTertiary,
                )
            }
            else -> {
                val visible = if (limit != null) list.take(limit) else list
                for (a in visible) ActivityCard(vm, a)
                if (limit != null && list.size > limit) {
                    NoopCard(modifier = Modifier.clickable(onClick = onSeeAll)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "Voir toutes mes activités (${list.size})",
                                style = NoopType.body, color = Palette.accent,
                                modifier = Modifier.weight(1f),
                            )
                            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Palette.textTertiary)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun IntervalsIcuActivitiesScreen(vm: AppViewModel) {
    ScreenScaffold(title = "Activités intervals.icu", subtitle = null) {
        IntervalsIcuActivitiesSection(vm, limit = null)
    }
}

private val debriefs = mutableStateMapOf<Long, String>()

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ActivityCard(vm: AppViewModel, a: WorkoutRow) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var loading by remember(a.startTs) { mutableStateOf(false) }
    var failed by remember(a.startTs) { mutableStateOf(false) }
    NoopCard(padding = 16.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(a.notes ?: a.sport, style = NoopType.body, color = Palette.textPrimary)
                    Text(dateString(a.startTs), style = NoopType.caption, color = Palette.textTertiary)
                }
                Icon(sportIcon(a.sport), contentDescription = null, tint = Palette.accent)
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                a.durationS?.let { StatPair("Durée", formatDuration(it)) }
                a.distanceM?.let { StatPair("Distance", "%.1f km".format(Locale.FRANCE, it / 1_000)) }
                a.avgHr?.let { StatPair("FC moy.", "$it bpm") }
                a.maxHr?.let { StatPair("FC max", "$it bpm") }
                a.energyKcal?.let { StatPair("Calories", "${Math.round(it)} kcal") }
            }
            val text = debriefs[a.startTs]
            when {
                text != null -> Text(text, style = NoopType.body, color = Palette.textSecondary)
                loading -> Text("L'IA débriefe la séance…", style = NoopType.caption, color = Palette.textTertiary)
                else -> Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    modifier = Modifier.clickable {
                        loading = true
                        failed = false
                        scope.launch {
                            runCatching { WorkoutDebrief.run(context, vm, a) }
                                .onSuccess { debriefs[a.startTs] = it }
                                .onFailure { failed = true }
                            loading = false
                        }
                    },
                ) {
                    Icon(Icons.Filled.AutoAwesome, contentDescription = null, tint = Palette.accent)
                    Text("Débriefer avec l'IA", style = NoopType.body, color = Palette.accent)
                }
            }
            if (failed) {
                Text(
                    "Configure ta clé API dans Coach > Réglages pour utiliser le débrief IA.",
                    style = NoopType.caption, color = Palette.statusWarning,
                )
            }
        }
    }
}

@Composable
private fun StatPair(label: String, value: String) {
    Column {
        Text(label, style = NoopType.footnote, color = Palette.textTertiary)
        Text(value, style = NoopType.caption, color = Palette.textPrimary)
    }
}

private fun sportIcon(sport: String): ImageVector {
    val s = sport.lowercase()
    return when {
        "ride" in s || "bike" in s || "cycl" in s -> Icons.AutoMirrored.Filled.DirectionsBike
        "run" in s || "walk" in s || "hike" in s -> Icons.AutoMirrored.Filled.DirectionsRun
        "swim" in s -> Icons.Filled.Pool
        "yoga" in s || "breath" in s || "respiration" in s -> Icons.Filled.SelfImprovement
        else -> Icons.Filled.FitnessCenter
    }
}

private fun dateString(ts: Long): String =
    SimpleDateFormat("d MMM yyyy 'à' HH:mm", Locale.FRANCE).format(Date(ts * 1000))

private fun formatDuration(seconds: Double): String {
    val total = seconds.toInt()
    val h = total / 3600
    val m = (total % 3600) / 60
    return if (h > 0) "${h}h${"%02d".format(m)}" else "$m min"
}
