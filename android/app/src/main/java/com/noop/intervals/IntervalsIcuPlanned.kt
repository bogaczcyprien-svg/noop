package com.noop.intervals

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.FitnessCenter
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.noop.ui.NoopCard
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ScreenScaffold
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.util.Locale

/** FORK: loads the next 21 days of planned WORKOUT events; null on no key or a failed fetch. */
private suspend fun loadPlanned(ctx: android.content.Context): List<IntervalsIcuEvent>? {
    val client = IntervalsIcuSettings.client(ctx) ?: return null
    return runCatching {
        client.events(IntervalsIcuDates.today(), IntervalsIcuDates.inDays(21), category = "WORKOUT")
    }.getOrNull()?.sortedBy { it.startDateLocal ?: "" }
}

/** FORK: Today's "Next session" card. Twin of the fork iOS `IntervalsICUNextPlannedCard`. */
@Composable
fun IntervalsIcuNextPlannedCard(onOpenCalendar: () -> Unit) {
    val context = LocalContext.current
    if (!IntervalsIcuSettings.hasApiKey(context)) return
    var events by remember { mutableStateOf<List<IntervalsIcuEvent>?>(null) }
    LaunchedEffect(Unit) { events = loadPlanned(context) }
    val next = events?.firstOrNull() ?: return

    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("INTERVALS.ICU", style = NoopType.caption, color = Palette.textTertiary)
        Text("Entraînements prévus", style = NoopType.headline, color = Palette.textPrimary)
        NoopCard(modifier = Modifier.clickable(onClick = onOpenCalendar)) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("PROCHAINE SÉANCE", style = NoopType.caption, color = Palette.textTertiary,
                        modifier = Modifier.weight(1f))
                    Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Palette.textTertiary)
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Icon(Icons.Filled.FitnessCenter, contentDescription = null, tint = Palette.accent)
                    Column {
                        Text(next.name ?: next.type ?: "Séance", style = NoopType.body, color = Palette.textPrimary)
                        Text(whenLabel(next), style = NoopType.caption, color = Palette.textSecondary)
                    }
                }
            }
        }
    }
}

/** FORK: the full 21-day planned calendar, grouped by day. Twin of the fork iOS `IntervalsICUPlannedScreen`. */
@Composable
fun IntervalsIcuPlannedScreen() {
    val context = LocalContext.current
    var events by remember { mutableStateOf<List<IntervalsIcuEvent>?>(null) }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { events = loadPlanned(context); loaded = true }

    ScreenScaffold(title = "Entraînements prévus", subtitle = "Calendrier intervals.icu, 21 prochains jours") {
        val list = events
        when {
            !IntervalsIcuSettings.hasApiKey(context) -> NoopCard {
                Text("Ajoutez votre clé intervals.icu dans les réglages pour voir votre calendrier.",
                    style = NoopType.body, color = Palette.textTertiary)
            }
            !loaded -> NoopCard { Text("Chargement…", style = NoopType.body, color = Palette.textTertiary) }
            list.isNullOrEmpty() -> NoopCard {
                Text("Aucun entraînement prévu dans les 21 prochains jours.", style = NoopType.body, color = Palette.textTertiary)
            }
            else -> {
                val byDay = list.groupBy { (it.startDateLocal ?: "").take(10) }
                for ((day, dayEvents) in byDay) {
                    Text(relativeDayLabel(day), style = NoopType.caption, color = Palette.textTertiary)
                    for (e in dayEvents) {
                        NoopCard(padding = 16.dp) {
                            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(e.name ?: e.type ?: "Séance", style = NoopType.body, color = Palette.textPrimary)
                                val details = listOfNotNull(
                                    e.type,
                                    timeLabel(e.startDateLocal),
                                    e.movingTime?.let { formatDuration(it) },
                                    e.distance?.let { "%.1f km".format(Locale.FRANCE, it / 1_000) },
                                ).joinToString(" · ")
                                if (details.isNotEmpty()) Text(details, style = NoopType.caption, color = Palette.textSecondary)
                                e.description?.takeIf { it.isNotBlank() }?.let {
                                    Text(it.trim(), style = NoopType.caption, color = Palette.textTertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun whenLabel(e: IntervalsIcuEvent): String {
    val day = relativeDayLabel((e.startDateLocal ?: "").take(10))
    return listOfNotNull(day, e.movingTime?.let { formatDuration(it) }).joinToString(" · ")
}

private fun relativeDayLabel(dayKey: String): String {
    val date = runCatching { LocalDate.parse(dayKey) }.getOrNull() ?: return dayKey
    val today = LocalDate.now()
    return when (date) {
        today -> "Aujourd'hui"
        today.plusDays(1) -> "Demain"
        else -> date.dayOfWeek.getDisplayName(TextStyle.FULL, Locale.FRANCE).replaceFirstChar { it.uppercase() } +
            " " + date.format(DateTimeFormatter.ofPattern("d MMM", Locale.FRANCE))
    }
}

private fun timeLabel(startDateLocal: String?): String? {
    val t = startDateLocal?.drop(11)?.take(5) ?: return null
    return if (t.length == 5 && t != "00:00") t else null
}

private fun formatDuration(seconds: Int): String {
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    return if (h > 0) "${h}h${"%02d".format(m)}" else "$m min"
}
