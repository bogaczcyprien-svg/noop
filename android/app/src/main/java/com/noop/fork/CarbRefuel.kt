package com.noop.fork

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.analytics.StrainScorer
import com.noop.analytics.WorkoutDetector
import com.noop.data.HrSample
import com.noop.data.WorkoutRow
import com.noop.nutrition.NutritionStore
import com.noop.ui.AppViewModel
import com.noop.ui.NoopCard
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ProfileStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.roundToInt

/** Fat/carb split of a session from its mean %HRR. Twin of Swift `SubstrateEstimator`. */
object SubstrateEstimator {
    private val controlPoints = listOf(0.0 to 70.0, 40.0 to 70.0, 55.0 to 55.0, 70.0 to 35.0, 85.0 to 15.0, 100.0 to 5.0)

    data class Estimate(val meanHRRPct: Double, val fatPct: Double, val carbPct: Double, val fatKcal: Double, val carbKcal: Double)

    fun fatPercent(hrrPct: Double): Double {
        val x = hrrPct.coerceIn(0.0, 100.0)
        if (x <= controlPoints.first().first) return controlPoints.first().second
        if (x >= controlPoints.last().first) return controlPoints.last().second
        for (i in 1 until controlPoints.size) {
            val (x1, y1) = controlPoints[i - 1]
            val (x2, y2) = controlPoints[i]
            if (x <= x2) return if (x2 > x1) y1 + (x - x1) / (x2 - x1) * (y2 - y1) else y2
        }
        return controlPoints.last().second
    }

    fun estimate(hr: List<HrSample>, restingHR: Double, maxHR: Double, totalKcal: Double): Estimate? {
        if (hr.isEmpty() || maxHR <= restingHR || totalKcal <= 0) return null
        val reserve = maxHR - restingHR
        val ordered = hr.sortedBy { it.ts }
        var sum = 0.0
        var w = 0.0
        for (i in ordered.indices) {
            val pct = StrainScorer.pctHRR(ordered[i].bpm.toDouble(), restingHR, reserve)
            val dur = if (i < ordered.lastIndex) {
                val gap = (ordered[i + 1].ts - ordered[i].ts).toDouble()
                if (gap > 0) minOf(gap, WorkoutDetector.mergeGapS) else 1.0
            } else 1.0
            sum += pct * dur
            w += dur
        }
        if (w <= 0) return null
        val mean = sum / w
        val fat = fatPercent(mean)
        return Estimate(mean, fat, 100 - fat, totalKcal * fat / 100, totalKcal * (100 - fat) / 100)
    }
}

/** Post-workout carb refuel target (ISSN, weight x duration). Twin of Swift `WorkoutCarbRefuelEstimator`. */
object WorkoutCarbRefuelEstimator {
    data class Refuel(val carbsBurnedG: Double, val refuelTargetG: Double, val windowHours: Double)

    const val G_PER_KG_PER_HOUR = 1.0
    const val MAX_WINDOW_HOURS = 4.0
    const val MIN_DURATION_MIN = 45.0
    const val MIN_CARB_KCAL = 150.0
    const val ROUND_TO_G = 5.0

    fun estimate(substrate: SubstrateEstimator.Estimate, weightKg: Double, durationS: Double): Refuel? {
        if (weightKg <= 0) return null
        if (durationS / 60.0 < MIN_DURATION_MIN && substrate.carbKcal < MIN_CARB_KCAL) return null
        val hours = minOf(durationS / 3600.0, MAX_WINDOW_HOURS)
        val target = Math.round(weightKg * G_PER_KG_PER_HOUR * hours / ROUND_TO_G).toDouble() * ROUND_TO_G
        return Refuel(substrate.carbKcal / 4.0, target, hours)
    }
}

private fun l(fr: String, en: String) = if (Locale.getDefault().language == "fr") fr else en

/** FORK: the "Refuel" card on a workout's detail sheet, twin of the fork iOS WorkoutDetailView card. */
@Composable
fun CarbRefuelCard(vm: AppViewModel, row: WorkoutRow) {
    val ctx = LocalContext.current
    var refuel by remember(row.startTs) { mutableStateOf<WorkoutCarbRefuelEstimator.Refuel?>(null) }
    var logged by remember(row.startTs) { mutableStateOf(false) }
    LaunchedEffect(row.startTs, row.endTs) {
        refuel = withContext(Dispatchers.IO) {
            runCatching {
                val kcal = row.energyKcal ?: return@runCatching null
                val profile = ProfileStore.from(ctx.applicationContext)
                val maxHR = if (profile.age > 0) StrainScorer.tanakaHRmax(profile.age.toDouble()) else StrainScorer.defaultMaxHR().toDouble()
                val resting = vm.recentDays.value.lastOrNull { it.restingHr != null }?.restingHr?.toDouble()
                    ?: StrainScorer.defaultRestingHR
                val hr = vm.repo.hrSamplesUnion(vm.activeStrapId, row.startTs, row.endTs)
                val sub = SubstrateEstimator.estimate(hr, resting, maxHR, kcal) ?: return@runCatching null
                WorkoutCarbRefuelEstimator.estimate(sub, profile.weightKg, row.durationS ?: (row.endTs - row.startTs).toDouble())
            }.getOrNull()
        }
    }
    val r = refuel ?: return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(l("RECHARGE — GLUCIDES APRÈS L'EFFORT", "REFUEL — POST-WORKOUT CARBS"), style = NoopType.footnote, color = Palette.textTertiary)
        NoopCard(tint = Palette.metricCyan) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    listOf(
                        l("Objectif", "Target") to "${r.refuelTargetG.roundToInt()}g",
                        l("Fenêtre", "Window") to "${r.windowHours.roundToInt()}h",
                        l("Cette séance", "This session") to "~${r.carbsBurnedG.roundToInt()}g",
                    ).forEach { (k, v) ->
                        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(k, style = NoopType.footnote, color = Palette.textTertiary)
                            Text(v, style = NoopType.headline, color = Palette.textPrimary)
                        }
                    }
                }
                OutlinedButton(
                    enabled = !logged,
                    onClick = {
                        NutritionStore.logMeal(ctx, l("Glucides de récupération", "Recovery carbs"), 0.0, r.refuelTargetG, 0.0)
                        logged = true
                    },
                ) { Text(if (logged) l("Enregistré ✓", "Logged ✓") else l("Ajouter comme repas", "Log as meal")) }
                Text(
                    l("D'après ton poids et la durée de cette séance — recommandations standard de nutrition sportive après l'effort (ISSN), pas un avis médical. « Cette séance » est une estimation séparée et approximative des glucides brûlés, ce n'est pas elle qui fixe l'objectif.",
                        "From your weight and this session's length — standard post-exercise sports-nutrition guidance (ISSN), not medical advice. \"This session\" is a separate, approximate estimate of carbs burned, not what sets the target."),
                    style = NoopType.footnote, color = Palette.textTertiary,
                )
            }
        }
    }
}
