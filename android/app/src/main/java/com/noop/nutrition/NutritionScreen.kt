package com.noop.nutrition

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.noop.ui.AppViewModel
import com.noop.ui.NoopButton
import com.noop.ui.NoopButtonKind
import com.noop.ui.NoopCard
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ProfileStore
import com.noop.ui.ScreenScaffold
import java.text.SimpleDateFormat
import java.time.LocalDate
import java.util.Date
import java.util.Locale

private val isFr get() = Locale.getDefault().language == "fr"
private fun l(fr: String, en: String) = if (isFr) fr else en

/** FORK: the Nutrition tab. Twin of the fork iOS `NutritionView`. */
@Composable
fun NutritionScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val today by vm.today.collectAsState()
    val days by vm.recentDays.collectAsState()
    var revision by remember { mutableIntStateOf(0) }
    var editing by remember { mutableStateOf<Meal?>(null) }
    var adding by remember { mutableStateOf(false) }

    @Suppress("UNUSED_VARIABLE") val tick = revision
    val weightKg = ProfileStore.from(context).weightKg
    val targets = MacroTargets.dailyTargets(weightKg, today?.strain, today?.activeKcalEst)
    val todayMeals = NutritionStore.mealsOn(context, LocalDate.now()).sortedBy { it.loggedAt }
    val eatenP = todayMeals.sumOf { it.proteinG }
    val eatenC = todayMeals.sumOf { it.carbsG }
    val eatenF = todayMeals.sumOf { it.fatG }
    val eatenKcal = todayMeals.sumOf { it.caloriesKcal }
    val templates = NutritionStore.templates(context)
    val totals = NutritionStore.dailyTotals(context)

    ScreenScaffold(title = l("Nutrition", "Nutrition"), subtitle = l("Tes macros du jour, réglées sur ton effort.", "Your macros for today, tuned to your effort.")) {
        NoopCard(padding = 16.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(l("MACROS DU JOUR", "TODAY'S MACROS"), style = NoopType.caption, color = Palette.textTertiary)
                MacroRow(l("Protéines", "Protein"), eatenP, targets.proteinG, Color(0xFFE5677F))
                MacroRow(l("Glucides", "Carbs"), eatenC, targets.carbsG, Color(0xFF4FC3D9))
                MacroRow(l("Lipides", "Fat"), eatenF, targets.fatG, Color(0xFFE8A93B))
            }
        }

        NoopCard(padding = 16.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(l("BILAN CALORIQUE", "CALORIE BALANCE"), style = NoopType.caption, color = Palette.textTertiary)
                val burned = today?.activeKcalEst
                if (burned != null) {
                    val delta = eatenKcal - burned
                    Text(
                        if (delta >= 0) l("+${Math.round(delta)} kcal de surplus", "+${Math.round(delta)} kcal surplus")
                        else l("${Math.round(-delta)} kcal de déficit", "${Math.round(-delta)} kcal deficit"),
                        style = NoopType.headline, color = Palette.textPrimary,
                    )
                    Text(l("Mangé ${Math.round(eatenKcal)} kcal · Dépensé ${Math.round(burned)} kcal", "Eaten ${Math.round(eatenKcal)} kcal · Burned ${Math.round(burned)} kcal"),
                        style = NoopType.caption, color = Palette.textSecondary)
                } else {
                    Text(l("Mangé ${Math.round(eatenKcal)} kcal", "Eaten ${Math.round(eatenKcal)} kcal"), style = NoopType.headline, color = Palette.textPrimary)
                    Text(l("Dépensé : pas encore assez de données cardiaques aujourd'hui.", "Burned: not enough heart-rate data yet today."),
                        style = NoopType.caption, color = Palette.textSecondary)
                }
            }
        }

        NoopCard(padding = 16.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(l("CETTE SEMAINE", "THIS WEEK"), style = NoopType.caption, color = Palette.textTertiary)
                val week = (6 downTo 0).map { LocalDate.now().minusDays(it.toLong()) }
                val logged = week.mapNotNull { d -> totals[d]?.let { d to it } }
                if (logged.size < 2) {
                    Text(l("Note quelques jours de plus pour voir une tendance.", "Log a few more days to see a trend."),
                        style = NoopType.caption, color = Palette.textSecondary)
                } else {
                    fun hits(index: Int, target: Int) = logged.count { target > 0 && it.second[index] >= target * 0.9 }
                    // FORK: per-macro 7-day bars with the on-target count, like the fork iOS weekly trend.
                    WeeklyMacroBars(l("Protéines", "Protein"), week.map { totals[it]?.get(1) ?: 0.0 }, Palette.metricRose,
                        l("Dans l'objectif ${hits(1, targets.proteinG)}/${logged.size} jours notés", "On target ${hits(1, targets.proteinG)}/${logged.size} logged days"))
                    WeeklyMacroBars(l("Glucides", "Carbs"), week.map { totals[it]?.get(2) ?: 0.0 }, Palette.metricCyan,
                        l("Dans l'objectif ${hits(2, targets.carbsG)}/${logged.size} jours notés", "On target ${hits(2, targets.carbsG)}/${logged.size} logged days"))
                    WeeklyMacroBars(l("Lipides", "Fat"), week.map { totals[it]?.get(3) ?: 0.0 }, Palette.metricAmber,
                        l("Dans l'objectif ${hits(3, targets.fatG)}/${logged.size} jours notés", "On target ${hits(3, targets.fatG)}/${logged.size} logged days"))
                    Text(l("Moyenne ${Math.round(logged.map { it.second[0] }.average())} kcal par jour noté",
                        "Average ${Math.round(logged.map { it.second[0] }.average())} kcal per logged day"), style = NoopType.caption, color = Palette.textSecondary)
                }
            }
        }

        if (templates.isNotEmpty()) {
            Text(l("AJOUT RAPIDE", "QUICK ADD"), style = NoopType.caption, color = Palette.textTertiary)
            Row(modifier = Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (t in templates) {
                    Row(
                        modifier = Modifier.clip(RoundedCornerShape(14.dp)).background(Palette.surfaceInset)
                            .clickable { NutritionStore.logFromTemplate(context, t); revision++ }
                            .padding(start = 12.dp, top = 6.dp, bottom = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Column {
                            Text(t.name, style = NoopType.body, color = Palette.textPrimary)
                            Text("${Math.round(MacroTargets.kcal(t.proteinG, t.carbsG, t.fatG))} kcal", style = NoopType.footnote, color = Palette.textSecondary)
                        }
                        IconButton(onClick = { NutritionStore.deleteTemplate(context, t.id); revision++ }) {
                            Icon(Icons.Filled.Delete, l("Supprimer", "Delete"), tint = Palette.textTertiary)
                        }
                    }
                }
            }
        }
        NoopButton(l("Ajouter un repas", "Add meal"), leadingIcon = Icons.Filled.AddCircle, kind = NoopButtonKind.Secondary,
            fullWidth = true, onClick = { adding = true })

        if (todayMeals.isNotEmpty()) {
            NoopCard(padding = 16.dp) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(l("REPAS DU JOUR", "TODAY'S MEALS"), style = NoopType.caption, color = Palette.textTertiary)
                    Text(l("Touche un repas pour le modifier, ou la corbeille pour le supprimer.", "Tap a meal to edit it, or use the trash to delete."),
                        style = NoopType.footnote, color = Palette.textTertiary)
                    for (m in todayMeals) {
                        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.clickable { editing = m }) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(m.name ?: l("Repas", "Meal"), style = NoopType.body, color = Palette.textPrimary)
                                Text("${SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(m.loggedAt * 1000))} · " +
                                    "${Math.round(m.proteinG)}g P · ${Math.round(m.carbsG)}g G · ${Math.round(m.fatG)}g L",
                                    style = NoopType.caption, color = Palette.textSecondary)
                            }
                            Text("${Math.round(m.caloriesKcal)} kcal", style = NoopType.caption, color = Palette.textPrimary)
                            IconButton(onClick = { NutritionStore.deleteMeal(context, m.id); revision++ }) {
                                Icon(Icons.Filled.Delete, l("Supprimer", "Delete"), tint = Palette.textTertiary)
                            }
                        }
                    }
                }
            }
        }

        NoopCard(padding = 16.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(l("NUTRITION ET RÉCUPÉRATION", "NUTRITION & RECOVERY"), style = NoopType.caption, color = Palette.textTertiary)
                val recovery = days.mapNotNull { d -> d.recovery?.let { runCatching { LocalDate.parse(d.day) }.getOrNull()?.to(it) } }.toMap()
                val series = mapOf(
                    l("Calories", "Calories") to totals.mapValues { it.value[0] },
                    l("Protéines", "Protein") to totals.mapValues { it.value[1] },
                    l("Glucides", "Carbs") to totals.mapValues { it.value[2] },
                )
                val insights = NutritionRecoveryInsights.insights(series, recovery).take(2)
                if (insights.isEmpty()) {
                    Text(l("Note tes repas sur plus de jours pour voir le lien entre la nutrition et la récupération du lendemain.",
                        "Log meals across more days to see how nutrition relates to tomorrow's recovery."), style = NoopType.caption, color = Palette.textSecondary)
                } else for (i in insights) {
                    val strength = when { kotlin.math.abs(i.r) >= 0.5 -> l("fort", "strong"); kotlin.math.abs(i.r) >= 0.3 -> l("modéré", "moderate"); else -> l("faible", "weak") }
                    val dir = if (i.r >= 0) l("positif", "positive") else l("négatif", "negative")
                    Text(l("${i.key} ↔ Réparation du lendemain : r = %+.2f (lien $strength $dir) sur ${i.n} jours.",
                        "${i.key} ↔ next-day Charge: r = %+.2f ($strength $dir) over ${i.n} days.").format(i.r),
                        style = NoopType.body, color = Palette.textPrimary)
                }
            }
        }
        Text(l("Les objectifs sont un repère approximatif tiré de ton poids et de l'effort du jour, pas un avis médical ou diététique.",
            "Targets are an approximate guide from your weight and today's effort — not medical or dietetic advice."),
            style = NoopType.footnote, color = Palette.textTertiary)
    }

    if (adding || editing != null) {
        MealDialog(editing, onDismiss = { adding = false; editing = null }, onSave = { name, p, c, f, asTemplate ->
            val e = editing
            if (e != null) NutritionStore.updateMeal(context, e.copy(name = name.ifBlank { null }, proteinG = p, carbsG = c, fatG = f))
            else NutritionStore.logMeal(context, name, p, c, f)
            if (asTemplate && name.isNotBlank()) NutritionStore.saveTemplate(context, name, p, c, f)
            adding = false; editing = null; revision++
        })
    }
}

@Composable
private fun MacroRow(label: String, eaten: Double, target: Int, tint: Color) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row {
            Text(label, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
            Text("${Math.round(eaten)}g / ${target}g", style = NoopType.caption, color = Palette.textSecondary)
        }
        val frac = if (target > 0) (eaten / target).coerceIn(0.0, 1.0).toFloat() else 0f
        Box(Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)).background(Palette.surfaceInset)) {
            Box(Modifier.fillMaxWidth(frac).height(8.dp).clip(RoundedCornerShape(4.dp)).background(tint))
        }
    }
}

@Composable
private fun MealDialog(meal: Meal?, onDismiss: () -> Unit, onSave: (String, Double, Double, Double, Boolean) -> Unit) {
    var name by remember { mutableStateOf(meal?.name ?: "") }
    var p by remember { mutableStateOf(meal?.proteinG?.let { Math.round(it).toString() } ?: "") }
    var c by remember { mutableStateOf(meal?.carbsG?.let { Math.round(it).toString() } ?: "") }
    var f by remember { mutableStateOf(meal?.fatG?.let { Math.round(it).toString() } ?: "") }
    var asTemplate by remember { mutableStateOf(false) }
    fun num(s: String) = s.replace(',', '.').toDoubleOrNull()?.coerceAtLeast(0.0) ?: 0.0
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (meal == null) l("Ajouter un repas", "Add meal") else l("Modifier le repas", "Edit meal")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(name, { name = it }, label = { Text(l("Nom (facultatif)", "Name (optional)")) }, singleLine = true)
                for ((label, value, set) in listOf(
                    Triple(l("Protéines (g)", "Protein (g)"), p) { v: String -> p = v },
                    Triple(l("Glucides (g)", "Carbs (g)"), c) { v: String -> c = v },
                    Triple(l("Lipides (g)", "Fat (g)"), f) { v: String -> f = v },
                )) {
                    OutlinedTextField(value, set, label = { Text(label) }, singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal))
                }
                Text("≈ ${Math.round(MacroTargets.kcal(num(p), num(c), num(f)))} kcal", style = NoopType.caption, color = Palette.textSecondary)
                if (meal == null) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(asTemplate, { asTemplate = it })
                        Text(l("Enregistrer comme favori", "Save as a favorite"), style = NoopType.body)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { onSave(name, num(p), num(c), num(f), asTemplate) }) { Text(l("Enregistrer", "Save")) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(l("Annuler", "Cancel")) } },
    )
}

/** FORK: one macro's grams per day over the last 7 days as bars, with its on-target line. */
@Composable
private fun WeeklyMacroBars(label: String, grams: List<Double>, tint: Color, onTarget: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp), modifier = Modifier.padding(top = 4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
            Text(onTarget, style = NoopType.footnote, color = Palette.textTertiary)
        }
        val maxV = (grams.maxOrNull() ?: 0.0).coerceAtLeast(1.0) * 1.15
        Row(
            Modifier.fillMaxWidth().height(56.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            grams.forEach { g ->
                Box(Modifier.weight(1f).fillMaxHeight(), contentAlignment = Alignment.BottomCenter) {
                    val frac = (g / maxV).toFloat().coerceIn(0f, 1f)
                    Box(
                        Modifier.fillMaxWidth().fillMaxHeight(if (g > 0) frac.coerceAtLeast(0.04f) else 0.02f)
                            .clip(RoundedCornerShape(topStart = 3.dp, topEnd = 3.dp))
                            .background(if (g > 0) tint else Palette.hairline),
                    )
                }
            }
        }
    }
}
