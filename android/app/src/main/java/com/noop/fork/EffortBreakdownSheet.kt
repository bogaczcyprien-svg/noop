package com.noop.fork

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Functions
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.noop.analytics.EffortBreakdownCalc
import com.noop.analytics.StrainScorer
import com.noop.ui.EffortScale
import com.noop.ui.NoopCard
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.UnitFormatter
import java.util.Locale
import kotlin.math.roundToInt

private fun l(fr: String, en: String) = if (Locale.getDefault().language == "fr") fr else en

/**
 * FORK: "What shaped your Effort" — twin of the fork iOS Effort breakdown sheet. Opened by tapping the
 * Effort ring on Today. The breakdown is the LIVE recompute with the same inputs as the ring's live value;
 * when the stored value is the one winning, the sheet says so instead of silently disagreeing.
 */
@Composable
fun EffortBreakdownSheet(
    breakdown: EffortBreakdownCalc.Breakdown?,
    isToday: Boolean,
    displayed: Double?,
    stored: Double?,
    live: Double?,
    effortScale: EffortScale,
    onClose: () -> Unit,
    onHowCalculated: () -> Unit,
    onOpenTrend: () -> Unit,
) {
    Surface(modifier = Modifier.fillMaxSize(), color = Palette.surfaceBase) {
        Column(Modifier.fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(l("Ce qui a façonné ton effort", "What shaped your Effort"), style = NoopType.headline,
                    color = Palette.textPrimary, modifier = Modifier.weight(1f))
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, contentDescription = l("Fermer", "Close"), tint = Palette.textSecondary)
                }
            }
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                if (isToday && displayed != null && (stored ?: -1.0) > (live ?: -1.0)) {
                    NoopCard(padding = 18.dp, tint = Palette.statusWarning) {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Icon(Icons.Filled.Warning, contentDescription = null, tint = Palette.statusWarning)
                                Text(l("Ce chiffre vient d'un calcul complet antérieur, pas du direct",
                                    "This number is from an earlier full scan, not live"),
                                    style = NoopType.subhead.copy(fontWeight = FontWeight.SemiBold), color = Palette.textPrimary)
                            }
                            Text(l("Affiché : ", "Shown: ") + UnitFormatter.effortDisplay(displayed, effortScale) +
                                l(" · Maintenant : ", " · Right now: ") + (live?.let { UnitFormatter.effortDisplay(it, effortScale) } ?: "—"),
                                style = NoopType.footnote, color = Palette.textTertiary)
                            Text(l("L'effort ne baisse jamais dans une journée, donc le plus haut des deux l'emporte. Le détail par zone ci-dessous est le recalcul en direct — il peut ne pas tout expliquer de ce que le calcul antérieur a vu.",
                                "Effort never drops within a day, so the higher of the two always wins. The zone breakdown below is the live recompute — it may not fully account for what the earlier scan saw."),
                                style = NoopType.footnote, color = Palette.textTertiary)
                        }
                    }
                }
                val b = breakdown
                if (b != null) {
                    NoopCard(padding = 18.dp, tint = Palette.effortColor) {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Pair(
                                l("Méthode", "Method") to if (b.method == StrainScorer.Method.BANISTER)
                                    l("Exponentielle (Banister)", "Exponential (Banister)") else l("Zones de FC (Edwards)", "Heart-rate zones (Edwards)"),
                                l("Ce calcul", "This computation") to UnitFormatter.effortDisplay(b.strain, effortScale),
                            ).let { StatPair(it) }
                            HorizontalDivider(color = Palette.hairline)
                            StatPair(Pair(
                                l("FC de repos utilisée", "Resting HR used") to "${b.restingHRUsed.roundToInt()} bpm",
                                l("FC max utilisée", "Max HR used") to "${b.hrMaxUsed.roundToInt()} bpm",
                            ))
                            HorizontalDivider(color = Palette.hairline)
                            StatPair(Pair(
                                l("Pic du jour", "Today's peak") to (b.peakBpm?.let { "${it.roundToInt()} bpm" } ?: "—"),
                                l("Pic soutenu", "Sustained peak") to (b.sustainedPeakBpm?.let { "${it.roundToInt()} bpm" } ?: "—"),
                            ))
                            val peak = b.peakBpm
                            val sustained = b.sustainedPeakBpm
                            if (peak != null && sustained != null && peak - sustained >= 15) {
                                Text(l("Ton pic est bien au-dessus de ce qui a tenu plus de quelques secondes — sans doute un pic du capteur, pas un vrai effort soutenu.",
                                    "Your peak reading is well above what held for more than a few seconds — likely a brief sensor spike, not sustained effort."),
                                    style = NoopType.footnote, color = Palette.statusWarning)
                            }
                        }
                    }
                    NoopCard(padding = 18.dp, tint = Palette.effortColor) {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            Text(l("TEMPS PAR ZONE", "TIME BY ZONE"), style = NoopType.footnote, color = Palette.textTertiary)
                            if (b.method == StrainScorer.Method.BANISTER) {
                                Text(l("Ton effort utilise la courbe exponentielle (Banister), qui n'utilise ni ces zones ni de plancher — elle compte chaque minute au-dessus de la FC de repos. Ces minutes par zone ne s'additionnent pas pour donner ton score ; regarde « Ce calcul » au-dessus pour le vrai total.",
                                    "Your Effort uses the exponential (Banister) curve, which doesn't use these zones or a floor — it credits every minute above resting HR. These zone minutes won't add up to your score; see \"This computation\" above for the real total."),
                                    style = NoopType.footnote, color = Palette.textTertiary)
                            }
                            val total = b.zoneMinutes.sum().coerceAtLeast(1.0)
                            (listOf(1, 2, 3, 4, 5, 0)).forEach { z -> ZoneRow(z, b.zoneMinutes.getOrElse(z) { 0.0 }, total) }
                        }
                    }
                } else {
                    NoopCard(padding = 18.dp, tint = Palette.effortColor) {
                        Text(l("Pas encore assez de données de fréquence cardiaque aujourd'hui pour détailler ce chiffre.",
                            "Not enough heart-rate data yet today to break this down."),
                            style = NoopType.subhead, color = Palette.textTertiary)
                    }
                }
                LinkRow(l("Comment l'effort est calculé", "How Effort is calculated"),
                    l("La méthode derrière le score, pas les valeurs du jour.", "The method behind the score, not today's values."),
                    onHowCalculated)
                LinkRow(l("Voir la tendance de l'effort", "See the Effort trend"), null, onOpenTrend)
            }
        }
    }
}

@Composable
private fun StatPair(p: Pair<Pair<String, String>, Pair<String, String>>) {
    Row(Modifier.fillMaxWidth()) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(p.first.first, style = NoopType.footnote, color = Palette.textTertiary)
            Text(p.first.second, style = NoopType.headline, color = Palette.textPrimary)
        }
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(p.second.first, style = NoopType.footnote, color = Palette.textTertiary)
            Text(p.second.second, style = NoopType.headline, color = Palette.textPrimary)
        }
    }
}

@Composable
private fun ZoneRow(zone: Int, minutes: Double, total: Double) {
    val label = if (zone == 0) l("Sous la zone 1", "Below zone 1") else "Zone $zone"
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(Modifier.fillMaxWidth()) {
            Text(label, style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f))
            Text("${minutes.roundToInt()} min", style = NoopType.bodyNumber, color = Palette.textSecondary)
        }
        Box(Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(3.dp)).background(Palette.hairline)) {
            val frac = (minutes / total).toFloat().coerceIn(0f, 1f)
            if (frac > 0f) {
                Box(Modifier.fillMaxWidth(frac).fillMaxHeight().background(
                    if (zone == 0) Palette.textTertiary else Palette.effortColor))
            }
        }
    }
}

@Composable
private fun LinkRow(title: String, subtitle: String?, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).clickable(onClick = onClick)
            .background(Palette.surfaceInset).padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Filled.Functions, contentDescription = null, tint = Palette.effortColor)
        Column(Modifier.weight(1f)) {
            Text(title, style = NoopType.subhead, color = Palette.textPrimary)
            subtitle?.let { Text(it, style = NoopType.footnote, color = Palette.textTertiary) }
        }
    }
}
