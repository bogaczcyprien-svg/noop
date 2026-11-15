package com.noop.fork

import android.app.TimePickerDialog
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.analytics.RaceTimePredictor
import com.noop.analytics.ResilienceEngine
import com.noop.data.JournalEntry
import com.noop.data.WhoopRepository
import com.noop.notif.SleepRecapNotifier
import com.noop.notif.TrendNotifier
import com.noop.notif.WorkoutNutritionNotifier
import com.noop.ui.AppViewModel
import com.noop.ui.NoopCard
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ScreenScaffold
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.util.Locale
import kotlin.math.roundToInt

// FORK: Android twins of the fork iOS More-list screens — race time predictor, fasting window logger,
// resilience and the sleep-recap notification settings. French copy, like the iOS fork screens.

@Composable
private fun Caption(text: String) {
    Text(text, style = NoopType.footnote, color = Palette.textTertiary)
}

@Composable
private fun LabelValue(label: String, value: String, accent: Boolean = true) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
        Text(value, style = NoopType.bodyNumber, color = if (accent) Palette.accent else Palette.textPrimary)
    }
}

private fun isoDay(daysAgo: Long): String = LocalDate.now().minusDays(daysAgo).toString()

@Composable
fun RaceTimePredictorScreen(vm: AppViewModel) {
    var vo2max by remember { mutableStateOf<Double?>(null) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        vo2max = withContext(Dispatchers.IO) {
            runCatching {
                vm.repo.resolvedSeries("vo2max_est", WhoopRepository.WHOOP_SOURCE, isoDay(3650), isoDay(0), vm.activeStrapId)
                    .points.maxByOrNull { it.day }?.value
            }.getOrNull()
        }
        loaded = true
    }
    ScreenScaffold(
        title = "Prédicteur de course",
        subtitle = "Temps estimés à partir de votre VO₂ Max — une approximation, pas une garantie.",
    ) {
        NoopCard(padding = 20.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
                val v = vo2max
                when {
                    v != null -> {
                        LabelValue("VO₂ Max", "${v.roundToInt()} ml/kg/min", accent = false)
                        RaceTimePredictor.estimate(v).forEach { est ->
                            LabelValue(est.distance.label, RaceTimePredictor.formatDuration(est.seconds))
                        }
                        Caption("Calculé à partir de deux relations publiées en physiologie de l'exercice (équation ACSM pour la course + fraction de VO₂ Max soutenable par distance), pas un modèle propriétaire. Ignore l'allure, le terrain, la météo et l'alimentation du jour — une estimation, pas une prédiction précise.")
                    }
                    loaded -> Text(
                        "Pas encore de VO₂ Max estimé — portez le bracelet régulièrement et renseignez votre tour de taille dans votre profil pour le débloquer.",
                        style = NoopType.subhead, color = Palette.textTertiary,
                    )
                    else -> Caption("Lecture de votre VO₂ Max…")
                }
            }
        }
    }
}

@Composable
fun ResilienceScreen(vm: AppViewModel) {
    var result by remember { mutableStateOf<ResilienceEngine.Result?>(null) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        result = withContext(Dispatchers.IO) {
            runCatching {
                val from = isoDay(60)
                val to = isoDay(0)
                val stress = vm.repo.resolvedSeries("stress", WhoopRepository.WHOOP_SOURCE, from, to, vm.activeStrapId)
                    .points.associate { it.day to it.value }
                val recovery = vm.repo.resolvedSeries("recovery", WhoopRepository.WHOOP_SOURCE, from, to, vm.activeStrapId)
                    .points.associate { it.day to it.value }
                val days = (stress.keys + recovery.keys).map { ResilienceEngine.DayInput(it, stress[it], recovery[it]) }
                ResilienceEngine.evaluate(days)
            }.getOrNull()
        }
        loaded = true
    }
    ScreenScaffold(
        title = "Résilience",
        subtitle = "Sur vos jours plus stressants, votre Réparation tient-elle le coup ?",
    ) {
        NoopCard(padding = 20.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val r = result
                when {
                    r != null -> {
                        Row(Modifier.fillMaxWidth()) {
                            Text(ResilienceEngine.bandLabelFr(r.band), style = NoopType.headline,
                                color = Palette.textPrimary, modifier = Modifier.weight(1f))
                            Text("${r.resilienceScore.roundToInt()}%", style = NoopType.headline, color = Palette.accent)
                        }
                        Caption("Moyenne de Réparation sur ${r.higherStressDayCount} jour(s) plus stressant(s) des 14 derniers jours.")
                    }
                    loaded -> Text(
                        "Pas encore assez de jours avec stress ET Réparation mesurés pour un résultat fiable — ça se construit avec le temps.",
                        style = NoopType.subhead, color = Palette.textTertiary,
                    )
                    else -> Caption("Lecture de votre historique…")
                }
            }
        }
    }
}

@Composable
fun FastingWindowScreen(vm: AppViewModel) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var lastMeal by remember { mutableIntStateOf(20 * 60) }   // yesterday, minutes since midnight
    var firstMeal by remember { mutableIntStateOf(8 * 60) }   // today
    var saved by remember { mutableStateOf(false) }
    val hours = ((24 * 60 - lastMeal) + firstMeal).coerceAtLeast(0) / 60.0

    fun pick(initial: Int, onPicked: (Int) -> Unit) {
        TimePickerDialog(ctx, { _, h, m -> onPicked(h * 60 + m); saved = false },
            initial / 60, initial % 60, true).show()
    }
    fun clock(m: Int) = String.format(Locale.ROOT, "%02d:%02d", m / 60, m % 60)

    ScreenScaffold(title = "Fenêtre de jeûne", subtitle = "Dernier repas d'hier soir → premier repas aujourd'hui.") {
        NoopCard(padding = 20.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Row(Modifier.fillMaxWidth().clickable { pick(lastMeal) { lastMeal = it } }.padding(vertical = 4.dp)) {
                    Text("Dernier repas (hier)", style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                    Text(clock(lastMeal), style = NoopType.bodyNumber, color = Palette.accent)
                }
                Row(Modifier.fillMaxWidth().clickable { pick(firstMeal) { firstMeal = it } }.padding(vertical = 4.dp)) {
                    Text("Premier repas (aujourd'hui)", style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                    Text(clock(firstMeal), style = NoopType.bodyNumber, color = Palette.accent)
                }
                Row(Modifier.fillMaxWidth()) {
                    Text("Durée du jeûne", style = NoopType.footnote, color = Palette.textTertiary, modifier = Modifier.weight(1f))
                    Text(String.format(Locale.ROOT, "%.1fh", hours), style = NoopType.headline, color = Palette.accent)
                }
                Button(
                    onClick = {
                        scope.launch(Dispatchers.IO) {
                            runCatching {
                                vm.repo.upsertJournal(listOf(JournalEntry(
                                    deviceId = "noop-journal", day = isoDay(0),
                                    question = "Fasting window (hours)", answeredYes = true, numericValue = hours,
                                )))
                                saved = true
                            }
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = Palette.accent),
                ) { Text(if (saved) "Enregistré ✓" else "Enregistrer") }
                Caption("Enregistré comme une entrée de Journal numérique standard — visible et corrélable à votre Réparation/sommeil dans Insights, comme vos autres entrées (café, alcool…).")
            }
        }
    }
}

@Composable
private fun ToggleCard(title: String, help: String, initial: Boolean, onChange: (Boolean) -> Unit) {
    var on by remember { mutableStateOf(initial) }
    NoopCard(padding = 20.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                Switch(
                    checked = on,
                    onCheckedChange = { on = it; onChange(it) },
                    colors = SwitchDefaults.colors(checkedTrackColor = Palette.accent),
                )
            }
            Caption(help)
        }
    }
}

@Composable
fun SleepRecapSettingsScreen() {
    val ctx = LocalContext.current
    ScreenScaffold(title = "Résumé de nuit", subtitle = "Des notifications locales — rien n'est envoyé en dehors de l'appareil.") {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ToggleCard(
                "Notification du matin",
                "Désactivé par défaut. Une fois activé, dès que la nuit précédente est calculée (après la synchro du bracelet), NOOP envoie une notification avec la durée, les phases (profond/REM/léger), l'efficacité, la Réparation du jour, une suggestion d'heure de coucher pour ce soir, et — si le réveil intelligent est activé — si l'heure de réveil réglée est tombée en sommeil léger ou non (information seulement, l'heure du réveil ne change pas automatiquement). Une seule fois par jour.",
                SleepRecapNotifier.isEnabled(ctx),
            ) { SleepRecapNotifier.setEnabled(ctx, it) }
            ToggleCard(
                "Notification de tendance HRV",
                "Désactivé par défaut. Prévient quand votre HRV est nettement au-dessus ou en-dessous de d'habitude depuis au moins 3 nuits de suite — une notification par tendance, pas une par jour. Distinct de l'alerte maladie, qui demande un motif plus précis sur plusieurs signaux.",
                TrendNotifier.isEnabled(ctx),
            ) { TrendNotifier.setEnabled(ctx, it) }
            ToggleCard(
                "Rappel nutrition après l'effort",
                "Désactivé par défaut. Une notification peu après la fin d'une séance détectée, pour penser à manger et vous hydrater dans l'heure qui suit — pas de journal alimentaire, juste un rappel de timing.",
                WorkoutNutritionNotifier.isEnabled(ctx),
            ) { WorkoutNutritionNotifier.setEnabled(ctx, it) }
        }
    }
}
