package com.noop.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.Locale

// FORK: Today "Your Cards" grouping, twin of the fork iOS LiquidTodayView change (37a0719b). A card whose
// number already sits on a Key Metrics tile is hidden; the rest are grouped into Form and Today (two-column
// tiles), Last night (one list card) and shortcuts (Coupled view / Coach). Values and routes are unchanged.

internal enum class ForkCardGroup { FITNESS, NIGHT, TODAY, SHORTCUTS }

internal enum class ForkCardStyle { ROW, TILE, LIST, SHORTCUT }

internal fun forkCardGroup(card: DashboardCard): ForkCardGroup = when (card) {
    DashboardCard.STRESS, DashboardCard.FITNESS_AGE, DashboardCard.VO2MAX, DashboardCard.VITALITY -> ForkCardGroup.FITNESS
    DashboardCard.SLEEP, DashboardCard.HRV, DashboardCard.RESTING_HR, DashboardCard.RESPIRATORY,
    DashboardCard.SKIN_TEMP, DashboardCard.BLOOD_OXYGEN -> ForkCardGroup.NIGHT
    DashboardCard.STEPS, DashboardCard.STEPS_AVERAGE_30, DashboardCard.CALORIES, DashboardCard.HYDRATION -> ForkCardGroup.TODAY
    else -> ForkCardGroup.SHORTCUTS
}

internal fun forkKeyMetricTwin(card: DashboardCard): KeyMetric? = when (card) {
    DashboardCard.HRV -> KeyMetric.HRV
    DashboardCard.RESTING_HR -> KeyMetric.RESTING_HR
    DashboardCard.RESPIRATORY -> KeyMetric.RESPIRATORY
    DashboardCard.STEPS, DashboardCard.STEPS_AVERAGE_30 -> KeyMetric.STEPS
    DashboardCard.BLOOD_OXYGEN -> KeyMetric.BLOOD_OXYGEN
    DashboardCard.SKIN_TEMP -> KeyMetric.SKIN_TEMP
    DashboardCard.CALORIES -> KeyMetric.CALORIES
    else -> null
}

internal fun forkStyleFor(group: ForkCardGroup): ForkCardStyle = when (group) {
    ForkCardGroup.FITNESS, ForkCardGroup.TODAY -> ForkCardStyle.TILE
    ForkCardGroup.NIGHT -> ForkCardStyle.LIST
    ForkCardGroup.SHORTCUTS -> ForkCardStyle.SHORTCUT
}

private fun fr() = Locale.getDefault().language == "fr"

@Composable
private fun GroupHeader(text: String) {
    Text(
        text.uppercase(Locale.getDefault()),
        style = NoopType.overline.copy(fontSize = 10.sp, letterSpacing = 1.2.sp),
        color = Palette.textTertiary,
        modifier = Modifier.padding(horizontal = 2.dp),
    )
}

@Composable
internal fun ForkCardGroupLayout(group: ForkCardGroup, cards: List<DashboardCard>, item: @Composable (DashboardCard) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        when (group) {
            ForkCardGroup.FITNESS -> GroupHeader(if (fr()) "Forme" else "Form")
            ForkCardGroup.TODAY -> GroupHeader(if (fr()) "Aujourd'hui" else "Today")
            ForkCardGroup.NIGHT -> GroupHeader(if (fr()) "La nuit dernière" else "Last night")
            ForkCardGroup.SHORTCUTS -> Unit
        }
        if (group == ForkCardGroup.NIGHT) {
            Column(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).frostedCardSurface(cornerRadius = 18.dp)
                    .padding(horizontal = 14.dp),
            ) {
                cards.forEachIndexed { i, c ->
                    item(c)
                    if (i < cards.lastIndex) HorizontalDivider(color = Palette.textTertiary.copy(alpha = 0.25f))
                }
            }
        } else {
            cards.chunked(2).forEach { pair ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Metrics.gap)) {
                    pair.forEach { c -> Box(Modifier.weight(1f)) { item(c) } }
                    if (pair.size == 1) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
internal fun ForkCompactCard(
    card: DashboardCard,
    value: String,
    hasValue: Boolean,
    tint: Color,
    style: ForkCardStyle,
    onClick: (() -> Unit)?,
) {
    val interaction = remember { MutableInteractionSource() }
    val title = uiString(card.titleRes)
    val stressBand = if (card == DashboardCard.STRESS) value.replace(',', '.').toDoubleOrNull()?.let { StressBand.forScore(it) } else null
    val tap: Modifier.() -> Modifier = {
        if (onClick != null) clickable(interactionSource = interaction, indication = null, onClick = onClick) else this
    }
    when (style) {
        ForkCardStyle.LIST -> Row(
            Modifier.fillMaxWidth().tap().padding(vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(tint))
            Text(title, style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f),
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(value, style = NoopType.number(16f), color = if (hasValue) Palette.textPrimary else Palette.textTertiary, maxLines = 1)
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(12.dp))
        }
        ForkCardStyle.SHORTCUT -> Row(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).frostedCardSurface(cornerRadius = 16.dp).tap()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(card.icon, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            Text(title, style = NoopType.subhead, color = Palette.textPrimary, modifier = Modifier.weight(1f),
                maxLines = 1, overflow = TextOverflow.Ellipsis)
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(12.dp))
        }
        else -> Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).frostedCardSurface(cornerRadius = 18.dp).tap()
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(card.icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
                Text(title.uppercase(Locale.getDefault()), style = NoopType.overline.copy(fontSize = 10.sp, letterSpacing = 1.0.sp),
                    color = Palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text(value, style = NoopType.number(22f), color = if (hasValue) Palette.textPrimary else Palette.textTertiary, maxLines = 1)
            if (stressBand != null) {
                val c = when (stressBand) {
                    StressBand.Low -> Palette.statusPositive
                    StressBand.Medium -> Palette.statusWarning
                    StressBand.High -> Palette.statusCritical
                }
                val label = when (stressBand) {
                    StressBand.Low -> if (fr()) "Faible" else "Low"
                    StressBand.Medium -> if (fr()) "Moyen" else "Medium"
                    StressBand.High -> if (fr()) "Élevé" else "High"
                }
                Text(label, style = NoopType.footnote, color = c)
            } else {
                Spacer(Modifier.height(2.dp))
            }
        }
    }
}
