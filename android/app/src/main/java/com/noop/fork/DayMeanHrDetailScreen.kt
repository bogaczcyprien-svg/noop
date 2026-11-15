package com.noop.fork

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.ui.AppViewModel
import com.noop.ui.LineChart
import com.noop.ui.Metrics
import com.noop.ui.NoopCard
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ScreenScaffold
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.LocalDate
import java.util.Locale
import kotlin.math.roundToInt

private fun l(fr: String, en: String) = if (Locale.getDefault().language == "fr") fr else en

/**
 * FORK: the Avg HR (24h) detail — twin of the fork iOS `DayMeanHRDetailView`. The whole-day mean HR
 * ("day_mean_hr") and, nested inside it, the night-only mean over the longest sleep session
 * ("rhr_primary_session"), both from the computed series, last 30 days.
 */
@Composable
fun DayMeanHrDetailScreen(vm: AppViewModel) {
    var day by remember { mutableStateOf<List<Double>>(emptyList()) }
    var night by remember { mutableStateOf<List<Double>>(emptyList()) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) {
            val from = LocalDate.now().minusDays(HISTORY_DAYS.toLong()).toString()
            suspend fun read(key: String) = runCatching {
                vm.repo.metricSeriesComputedUnion(vm.activeStrapId, key, from, "9999-12-31")
                    .sortedBy { it.day }.map { it.value }
            }.getOrDefault(emptyList())
            day = read("day_mean_hr")
            night = read("rhr_primary_session")
        }
        loaded = true
    }

    ScreenScaffold(
        title = l("FC moy. (24 h)", "Avg HR (24h)"),
        subtitle = l("Toute la journée, nuit comprise.", "Whole day, including the night."),
    ) {
        NoopCard(padding = 18.dp) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                StatColumn(l("Toute la journée", "Whole day"), day.lastOrNull(), Palette.metricRose, Modifier.weight(1f))
                StatColumn(l("Nuit seule", "Night only"), night.lastOrNull(), Palette.metricPurple, Modifier.weight(1f))
            }
        }
        if (loaded) {
            TrendCard(l("Toute la journée", "Whole day"), day, Palette.metricRose)
            TrendCard(l("Nuit seule", "Night only"), night, Palette.metricPurple)
        }
        Text(
            l("Le chiffre de la journée est la fréquence cardiaque moyenne sur toute la journée, sommeil compris. Le chiffre de la nuit est la moyenne sur ta plus longue période de sommeil. Les deux sont approximatifs.",
                "The whole-day figure is the mean heart rate across the entire day, including sleep. The night-only figure is the mean over your longest sleep session. Both are approximate."),
            style = NoopType.footnote, color = Palette.textTertiary,
        )
    }
}

private const val HISTORY_DAYS = 30

@Composable
private fun StatColumn(label: String, value: Double?, tint: Color, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(label, style = NoopType.caption, color = Palette.textTertiary)
        Text(value?.let { "${it.roundToInt()} bpm" } ?: "—",
            style = NoopType.number(24f).copy(fontWeight = FontWeight.Bold), color = tint)
    }
}

@Composable
private fun TrendCard(title: String, values: List<Double>, tint: Color) {
    NoopCard(padding = 18.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(Metrics.gap)) {
            Text(title.uppercase(Locale.getDefault()), style = NoopType.caption, color = Palette.textTertiary)
            if (values.size >= 2) {
                LineChart(
                    values = values,
                    modifier = Modifier.fillMaxWidth().height(Metrics.chartHeight),
                    color = tint,
                    selectionEnabled = true,
                    formatValue = { "${it.roundToInt()} bpm" },
                )
            } else {
                Box(Modifier.fillMaxWidth().height(Metrics.chartHeight), contentAlignment = Alignment.Center) {
                    Text(l("Pas assez de données sur cette période.", "Not enough data for this window."),
                        style = NoopType.subhead, color = Palette.textTertiary)
                }
            }
        }
    }
}
