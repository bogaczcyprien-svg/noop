package com.noop.breathing

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.noop.analytics.BreathPhase
import com.noop.analytics.BreathingExercise
import com.noop.analytics.BreathingHistory
import com.noop.analytics.BreathingProgression
import com.noop.analytics.BreathingScienceCatalog
import com.noop.analytics.BreathingScienceCatalog.tr
import com.noop.analytics.ResonanceEngine
import com.noop.intervals.IntervalsIcuSettings
import com.noop.ui.AppViewModel
import com.noop.ui.BiofeedbackPrefs
import com.noop.ui.NoopButton
import com.noop.ui.NoopButtonKind
import com.noop.ui.NoopCard
import com.noop.ui.NoopPrefs
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ScreenScaffold
import com.noop.ui.SettingsToggleRow
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

private val isFr get() = Locale.getDefault().language == "fr"
private fun l(fr: String, en: String) = if (isFr) fr else en

/**
 * FORK: the Breathing tab — research-backed exercises with levels, progress, free-breathing baseline,
 * bedtime reminder and intervals.icu upload. Twin of the fork iOS `BreathingTabView`, without the CORE
 * sensor; beat-to-beat data comes from the chest strap when one is connected, else from the WHOOP.
 */
@Composable
fun BreathingTabScreen(vm: AppViewModel, onMoreTechniques: () -> Unit) {
    val context = LocalContext.current
    var history by remember { mutableStateOf(BreathingHistoryStore.load(context)) }
    var freeMinutes by remember { mutableIntStateOf(NoopPrefs.of(context).getInt(KEY_FREE_MINUTES, 10)) }
    var nudgeOn by remember { mutableStateOf(BedtimeBreathingNudge.isEnabled(context)) }
    var detail by remember { mutableStateOf<BreathingExercise?>(null) }
    var session by remember { mutableStateOf<BreathingSession?>(null) }
    val scope = rememberCoroutineScope()
    val strapState by BreathingStrapLink.state.collectAsState()
    val strapName by BreathingStrapLink.strapName.collectAsState()
    val strapHr by BreathingStrapLink.heartRate.collectAsState()
    val strapFound by BreathingStrapLink.found.collectAsState()
    var showStrapPicker by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { BreathingStrapLink.reconnectLast(context) }

    fun start(ex: BreathingExercise) {
        val s = BreathingSession(context, vm, BreathingLevelStore.current(context, ex), freeMinutes * 60, scope)
        BedtimeBreathingNudge.noteSessionDone(context)
        session = s
        s.start()
    }

    ScreenScaffold(title = tr("Breathing"), subtitle = tr("Exercises backed by research, guided by your heart.")) {
        // Chest strap (fork iOS strapCard): its beats win over the WHOOP's when it is connected.
        NoopCard(padding = 16.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(l("CEINTURE CARDIO", "CHEST STRAP"), style = NoopType.caption, color = Palette.textTertiary)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    val on = strapState == BreathingStrapLink.State.CONNECTED
                    Icon(
                        if (on) Icons.Filled.Favorite else Icons.Filled.FavoriteBorder, null,
                        tint = if (on) Palette.accent else Palette.textTertiary,
                    )
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            when (strapState) {
                                BreathingStrapLink.State.CONNECTED -> strapName ?: l("Ceinture cardio", "Chest strap")
                                BreathingStrapLink.State.CONNECTING -> l("Connexion…", "Connecting…")
                                BreathingStrapLink.State.SCANNING -> l("Recherche…", "Searching…")
                                BreathingStrapLink.State.BLUETOOTH_OFF -> l("Le Bluetooth est coupé", "Bluetooth is off")
                                else -> l("Aucune ceinture connectée", "No strap connected")
                            },
                            style = NoopType.headline, color = Palette.textPrimary,
                        )
                        Text(
                            if (on) tr("Beat-to-beat data: breathing rate, HRV and coherence are measured live.")
                            else l("Sans ceinture, la fréquence cardiaque du WHOOP est utilisée ; elle est moins précise battement par battement.",
                                "Without a strap, the WHOOP's heart rate is used; it is less precise beat to beat."),
                            style = NoopType.caption, color = Palette.textSecondary,
                        )
                    }
                    strapHr?.takeIf { on }?.let {
                        Text("$it", style = NoopType.headline.copy(fontSize = 28.sp), color = Palette.textPrimary)
                    }
                }
                if (strapState == BreathingStrapLink.State.CONNECTED) {
                    NoopButton(l("Déconnecter", "Disconnect"), kind = NoopButtonKind.Secondary, fullWidth = true) {
                        BreathingStrapLink.disconnect()
                    }
                } else {
                    NoopButton(l("Trouver ma ceinture", "Find my strap"), fullWidth = true) {
                        BreathingStrapLink.scan(context)
                        showStrapPicker = true
                    }
                }
            }
        }

        // Progress
        NoopCard(padding = 16.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(tr("Your progress").uppercase(), style = NoopType.caption, color = Palette.textTertiary)
                if (history.isEmpty()) {
                    Text(tr("Do a few sessions to see your progress here."), style = NoopType.body, color = Palette.textSecondary)
                } else {
                    val now = System.currentTimeMillis() / 1000
                    Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                        Stat(l("7 derniers jours", "Last 7 days"), "${BreathingHistory.sessionsLast7Days(history, now)}", tr("sessions"))
                        Stat(l("Série", "Streak"), "${BreathingHistory.streakDays(history, LocalDate.now(), ZoneId.systemDefault())}", tr("days"))
                    }
                    val points = history.takeLast(30).mapNotNull { it.avgCoherence }
                    if (points.size >= 2) {
                        Text(tr("Coherence per session"), style = NoopType.caption, color = Palette.textSecondary)
                        CoherenceSparkline(points)
                    }
                    BreathingHistory.trend(history) { it.avgCoherence }?.let { (recent, previous) ->
                        Text(
                            l("Cohérence, 7 dernières séances : ${Math.round(recent)}/100 (${signed(recent - previous)} par rapport aux 7 d'avant).",
                                "Coherence, last 7 sessions: ${Math.round(recent)}/100 (${signed(recent - previous)} vs the 7 before)."),
                            style = NoopType.body, color = Palette.textPrimary,
                        )
                    } ?: Text(
                        l("La tendance s'affiche après ${2 * BreathingHistory.TREND_WINDOW} séances.",
                            "The trend shows after ${2 * BreathingHistory.TREND_WINDOW} sessions."),
                        style = NoopType.caption, color = Palette.textTertiary,
                    )
                    BreathingHistory.trend(history) { it.hrChange }?.let { (recent, previous) ->
                        Text(
                            l("FC pendant l'exercice, 7 dernières séances : ${signed(recent)} bpm par rapport à la respiration libre (les 7 d'avant : ${signed(previous)}).",
                                "Heart rate during the exercise, last 7 sessions: ${signed(recent)} bpm vs free breathing (the 7 before: ${signed(previous)})."),
                            style = NoopType.body, color = Palette.textPrimary,
                        )
                    }
                }
            }
        }

        // Free breathing before the exercise
        NoopCard(padding = 16.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(l("AVANT L'EXERCICE", "BEFORE THE EXERCISE"), style = NoopType.caption, color = Palette.textTertiary)
                Text(
                    l("D'abord de la respiration libre : respire normalement pendant qu'on enregistre ta base, puis l'exercice guidé démarre.",
                        "Free breathing first: breathe normally while your baseline is recorded, then the guided exercise starts."),
                    style = NoopType.caption, color = Palette.textSecondary,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (m in listOf(0, 2, 5, 10)) {
                        val selected = m == freeMinutes
                        Box(
                            modifier = Modifier
                                .background(if (selected) Palette.accent else Palette.surfaceInset, CircleShape)
                                .clickable {
                                    freeMinutes = m
                                    NoopPrefs.of(context).edit().putInt(KEY_FREE_MINUTES, m).apply()
                                }
                                .padding(horizontal = 14.dp, vertical = 8.dp),
                        ) {
                            Text(if (m == 0) l("Aucune", "None") else "$m min", style = NoopType.caption,
                                color = if (selected) Palette.surfaceBase else Palette.textPrimary)
                        }
                    }
                }
            }
        }

        // Exercises
        Text(l("EXERCICES", "EXERCISES"), style = NoopType.caption, color = Palette.textTertiary)
        for (ex in BreathingScienceCatalog.all) {
            NoopCard(padding = 16.dp, modifier = Modifier.clickable { detail = ex }) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(ex.title, style = NoopType.headline, color = Palette.textPrimary)
                        Text(ex.subtitle, style = NoopType.caption, color = Palette.textSecondary)
                        ex.benefits.firstOrNull()?.let {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                Icon(Icons.Filled.Check, null, tint = Palette.accent, modifier = Modifier.size(14.dp))
                                Text(it, style = NoopType.caption, color = Palette.textSecondary)
                            }
                        }
                        if (BreathingProgression.isProgressive(ex.id)) {
                            val level = BreathingLevelStore.state(context, ex.id).level
                            Text(l("Niveau", "Level") + " $level/${BreathingProgression.maxLevel(ex.id)}" +
                                (levelDetail(ex.id, level)?.let { " · $it" } ?: ""),
                                style = NoopType.caption, color = Palette.accent)
                        }
                        if (ex.id == BreathingScienceCatalog.RESONANCE_ID || ex.id == BreathingScienceCatalog.RESONANCE_TEST_ID) {
                            BiofeedbackPrefs.lockedPace(context)?.let { bpm ->
                                Text(l("Ton rythme : %.1f respirations/min", "Your pace: %.1f breaths/min").format(bpm),
                                    style = NoopType.caption, color = Palette.accent)
                            }
                        }
                    }
                    Icon(Icons.Filled.ChevronRight, null, tint = Palette.textTertiary)
                }
            }
        }
        NoopCard(padding = 16.dp, modifier = Modifier.clickable(onClick = onMoreTechniques)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(tr("More techniques"), style = NoopType.headline, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                Icon(Icons.Filled.ChevronRight, null, tint = Palette.textTertiary)
            }
        }

        // Bedtime reminder
        NoopCard(padding = 16.dp) {
            SettingsToggleRow(
                title = l("Rappel au coucher", "Bedtime reminder"),
                detail = l("Entre 21 h et 23 h, quand le bracelet te voit allongé, immobile et pas encore endormi, une notification te propose la cohérence cardiaque.",
                    "Between 9 and 11 pm, when the strap sees you lying still and not yet asleep, a notification suggests cardiac coherence."),
                checked = nudgeOn,
                onCheckedChange = {
                    nudgeOn = it
                    BedtimeBreathingNudge.setEnabled(context, it)
                },
            )
        }

        // intervals.icu
        NoopCard(padding = 16.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("INTERVALS.ICU", style = NoopType.caption, color = Palette.textTertiary)
                Text(
                    if (IntervalsIcuSettings.hasApiKey(context))
                        l("Chaque séance est envoyée comme une activité : fréquence cardiaque, fréquence respiratoire et chaque battement.",
                            "Each session is sent as an activity: heart rate, breathing rate and every heartbeat.")
                    else l("Ajoute ta clé API intervals.icu dans les réglages pour envoyer chaque séance comme une activité.",
                        "Add your intervals.icu API key in Settings to send each session as an activity."),
                    style = NoopType.caption, color = Palette.textSecondary,
                )
            }
        }
        Text(tr("Breathing exercises are a wellness practice, not medical treatment. Stop if you feel dizzy."),
            style = NoopType.footnote, color = Palette.textTertiary)
    }

    detail?.let { ex ->
        ExerciseDetailDialog(ex, onDismiss = { detail = null }, onStart = { detail = null; start(ex) })
    }
    session?.let { s ->
        BreathingSessionDialog(s, onClose = {
            session = null
            history = BreathingHistoryStore.load(context)
        })
    }
    if (showStrapPicker) {
        StrapPickerDialog(
            found = strapFound,
            bluetoothOff = strapState == BreathingStrapLink.State.BLUETOOTH_OFF,
            onPick = { addr -> showStrapPicker = false; BreathingStrapLink.connect(context, addr) },
            onDismiss = { showStrapPicker = false; BreathingStrapLink.stopScan() },
        )
    }
}

private const val KEY_FREE_MINUTES = "noop.breathing.freeMinutes"

/** Scan results for the Breathing-tab chest strap. Twin of the fork iOS `SensorPickerSheet`. */
@Composable
private fun StrapPickerDialog(
    found: List<BreathingStrapLink.Found>,
    bluetoothOff: Boolean,
    onPick: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(l("Choisir une ceinture", "Choose a strap")) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                if (bluetoothOff) {
                    Text(l("Active le Bluetooth pour trouver ta ceinture.", "Turn Bluetooth on to find your strap."),
                        style = NoopType.body, color = Palette.textSecondary)
                } else if (found.isEmpty()) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        Text(l("Mets la ceinture (mouille les capteurs) et garde le téléphone près de toi.",
                            "Put the strap on (wet the sensors) and keep the phone close."),
                            style = NoopType.body, color = Palette.textSecondary)
                    }
                }
                found.forEach { s ->
                    Row(
                        Modifier.fillMaxWidth().clickable { onPick(s.address) }.padding(vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(s.name, style = NoopType.body, color = Palette.textPrimary, modifier = Modifier.weight(1f))
                        Text("${s.rssi} dBm", style = NoopType.caption, color = Palette.textTertiary)
                    }
                }
            }
        },
        confirmButton = {},
        dismissButton = { TextButton(onClick = onDismiss) { Text(l("Annuler", "Cancel")) } },
    )
}

private fun signed(v: Double): String {
    val r = Math.round(v).toInt()
    return if (r > 0) "+$r" else if (r < 0) "−${-r}" else "0"
}

private fun levelDetail(id: String, level: Int): String? = when (id) {
    BreathingScienceCatalog.CO2_ID -> l("retenue ${BreathingProgression.co2HoldSeconds(level)} s", "hold ${BreathingProgression.co2HoldSeconds(level)} s")
    BreathingScienceCatalog.BREATH_HOLDS_ID -> {
        val (rounds, cap) = BreathingProgression.breathHolds(level)
        l("$rounds apnées, max $cap s", "$rounds holds, max $cap s")
    }
    BreathingScienceCatalog.RESPIRATORY_MUSCLE_ID -> l("${BreathingProgression.muscleBreaths(level)} respirations", "${BreathingProgression.muscleBreaths(level)} breaths")
    else -> null
}

@Composable
private fun Stat(label: String, value: String, caption: String) {
    Column {
        Text(label, style = NoopType.caption, color = Palette.textTertiary)
        Text(value, style = NoopType.headline.copy(fontSize = 26.sp), color = Palette.textPrimary)
        Text(caption, style = NoopType.footnote, color = Palette.textSecondary)
    }
}

@Composable
private fun CoherenceSparkline(values: List<Double>) {
    val color = Palette.accent
    Canvas(modifier = Modifier.fillMaxWidth().height(100.dp)) {
        if (values.size < 2) return@Canvas
        val stepX = size.width / (values.size - 1)
        for (i in 1 until values.size) {
            val y0 = size.height * (1 - (values[i - 1] / 100.0).toFloat())
            val y1 = size.height * (1 - (values[i] / 100.0).toFloat())
            drawLine(color, Offset((i - 1) * stepX, y0), Offset(i * stepX, y1), strokeWidth = 4f)
        }
    }
}

@Composable
private fun ExerciseDetailDialog(ex: BreathingExercise, onDismiss: () -> Unit, onStart: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(ex.title) },
        text = {
            Column(modifier = Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(ex.subtitle, style = NoopType.caption, color = Palette.textSecondary)
                for (b in ex.benefits) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.Check, null, tint = Palette.accent, modifier = Modifier.size(16.dp))
                        Text(b, style = NoopType.body)
                    }
                }
                Text(l("Comment faire", "How to"), style = NoopType.headline)
                Text(ex.howTo, style = NoopType.body)
                Text(l("Ce que dit la science", "What the evidence says"), style = NoopType.headline)
                Text(ex.evidence, style = NoopType.caption, color = Palette.textSecondary)
                ex.caution?.let { Text(it, style = NoopType.caption, color = Palette.statusWarning) }
            }
        },
        confirmButton = { TextButton(onClick = onStart) { Text(l("Commencer", "Start")) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(l("Fermer", "Close")) } },
    )
}

@Composable
private fun BreathingSessionDialog(session: BreathingSession, onClose: () -> Unit) {
    val ui by session.ui.collectAsState()
    Dialog(onDismissRequest = {}, properties = DialogProperties(usePlatformDefaultWidth = false, dismissOnBackPress = false)) {
        Column(
            modifier = Modifier.fillMaxSize().background(Palette.surfaceBase).padding(24.dp)
                .verticalScroll(rememberScrollState()),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text(session.exercise.title, style = NoopType.headline, color = Palette.textPrimary, textAlign = TextAlign.Center)
            val summary = ui.summary
            if (summary == null) {
                Text(partLabel(session, ui), style = NoopType.caption, color = Palette.textSecondary, textAlign = TextAlign.Center)
                Spacer(Modifier.height(8.dp))
                PacerCircle(ui.pacer)
                Text(pacerText(ui), style = NoopType.headline.copy(fontSize = 22.sp), color = Palette.textPrimary, textAlign = TextAlign.Center)
                ui.sweepPace?.let { Text(l("Rythme %.1f / min", "Pace %.1f / min").format(it), style = NoopType.caption, color = Palette.textSecondary) }
                Row(horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    LiveStat(l("Fréquence cardiaque", "Heart rate"), ui.heartRate?.let { "$it" } ?: "—")
                    LiveStat(l("Respiration", "Breathing"), ui.breathsPerMin?.let { "%.1f".format(it) } ?: "—")
                    LiveStat(l("Cohérence", "Coherence"), ui.coherence?.let { "${Math.round(it)}" } ?: "—")
                    LiveStat("HRV", ui.rmssd?.let { "${Math.round(it)}" } ?: "—")
                }
                when (ui.part) {
                    BreathingSession.Part.Free -> NoopButton(l("Passer à l'exercice", "Skip to the exercise"),
                        kind = NoopButtonKind.Secondary, fullWidth = true, onClick = session::skipFree)
                    is BreathingSession.Part.Hold -> NoopButton(l("Je respire à nouveau", "I'm breathing again"),
                        fullWidth = true, onClick = session::endHold)
                    else -> Unit
                }
                NoopButton(l("Arrêter", "Stop"), kind = NoopButtonKind.Secondary, fullWidth = true, onClick = session::stop)
            } else {
                SummaryView(session, summary, ui.upload)
                NoopButton(l("Fermer", "Close"), fullWidth = true, onClick = onClose)
            }
        }
    }
}

private fun clock(seconds: Int) = "%d:%02d".format(seconds / 60, seconds % 60)

private fun partLabel(s: BreathingSession, ui: BreathingSession.Ui): String = when (val p = ui.part) {
    BreathingSession.Part.Free -> l("Respiration libre · ${clock(maxOf(0, s.freeSeconds - ui.partElapsed))} restantes",
        "Free breathing · ${clock(maxOf(0, s.freeSeconds - ui.partElapsed))} left")
    BreathingSession.Part.Guided -> l("Exercice · ${clock(maxOf(0, s.guidedSeconds - ui.partElapsed))} restantes",
        "Exercise · ${clock(maxOf(0, s.guidedSeconds - ui.partElapsed))} left")
    is BreathingSession.Part.Recovery -> l("Respiration calme · tour ${p.round}", "Calm breathing · round ${p.round}")
    is BreathingSession.Part.Hold -> l("Apnée · tour ${p.round}", "Hold · round ${p.round}")
    BreathingSession.Part.Done -> ""
}

private fun pacerText(ui: BreathingSession.Ui): String {
    val p = ui.pacer ?: return if (ui.part == BreathingSession.Part.Free) l("Respire normalement", "Breathe normally") else ""
    val word = p.label ?: when (p.phase) {
        BreathPhase.INHALE -> l("Inspire", "Breathe in")
        BreathPhase.EXHALE -> l("Expire", "Breathe out")
        else -> l("Bloque", "Hold")
    }
    return "$word · ${p.secondsLeft}"
}

@Composable
private fun PacerCircle(p: BreathingSession.Pacer?) {
    val fill = (p?.fill ?: 0.3).toFloat()
    val accent = Palette.accent
    val ring = Palette.hairline
    Canvas(modifier = Modifier.size(220.dp)) {
        val maxR = size.minDimension / 2
        drawCircle(ring, radius = maxR, style = Stroke(width = 3f))
        drawCircle(accent.copy(alpha = 0.35f), radius = maxR * (0.35f + 0.65f * fill))
        drawCircle(accent, radius = maxR * (0.35f + 0.65f * fill), style = Stroke(width = 6f))
    }
}

@Composable
private fun LiveStat(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, style = NoopType.headline, color = Palette.textPrimary)
        Text(label, style = NoopType.footnote, color = Palette.textTertiary, textAlign = TextAlign.Center)
    }
}

@Composable
private fun SummaryView(session: BreathingSession, s: BreathingSession.Summary, upload: BreathingSession.Upload) {
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        PartCard(l("Respiration libre", "Free breathing"), s.free)
        PartCard(l("Exercice", "Exercise"), s.guided)
        if (s.holdsSeconds.isNotEmpty()) {
            Text(l("Apnées : ", "Breath holds: ") + s.holdsSeconds.joinToString(", ") { "$it s" } +
                l(" · meilleure ${s.holdsSeconds.max()} s", " · best ${s.holdsSeconds.max()} s"),
                style = NoopType.body, color = Palette.textPrimary)
        }
        val freeHr = s.free.avgHR
        val guidedHr = s.guided.avgHR
        if (s.free.seconds > 0 && freeHr != null && guidedHr != null) {
            val diff = Math.round(guidedHr - freeHr).toInt()
            Text(
                if (diff < 0) l("Ta fréquence cardiaque a baissé de ${-diff} bpm pendant l'exercice.", "Your heart rate dropped by ${-diff} bpm during the exercise.")
                else l("Ta fréquence cardiaque est restée à $diff bpm de la respiration libre.", "Your heart rate stayed within $diff bpm of free breathing."),
                style = NoopType.body, color = Palette.textPrimary,
            )
        }
        s.resonanceBpm?.let { bpm ->
            Text(
                if (s.resonanceLocked) l("Ton rythme de résonance : %.1f respirations/min.", "Your resonance pace: %.1f breaths/min.").format(bpm)
                else l("Aucun rythme de résonance enregistré : pas assez de battements propres. Va au bout du test, reste immobile et porte le bracelet bien serré (au moins ${ResonanceEngine.MIN_SCORED_PACES} rythmes doivent être mesurés).",
                    "No resonance pace saved: not enough clean heartbeats. Go to the end of the test, stay still and wear the strap snug (at least ${ResonanceEngine.MIN_SCORED_PACES} paces must be measured)."),
                style = NoopType.body, color = Palette.textPrimary,
            )
        }
        s.progression?.let { p ->
            val max = BreathingProgression.maxLevel(session.exercise.id)
            Text(
                when {
                    !p.completedFully -> l("Arrêtée avant la fin : cette séance ne compte pas pour le niveau suivant.", "Stopped before the end: this session does not count toward the next level.")
                    p.leveledUp -> l("Niveau supérieur : niveau ${p.after.level} sur $max. La prochaine séance est plus dure.", "Level up: level ${p.after.level} of $max. The next session is harder.")
                    p.after.level >= max -> l("Niveau maximum atteint. Continue pour garder tes progrès.", "Top level reached. Keep it up to hold your gains.")
                    else -> l("Niveau ${p.after.level} : ${p.after.completions}/${BreathingProgression.sessionsPerLevel(session.exercise.id)} séances avant le suivant.",
                        "Level ${p.after.level}: ${p.after.completions}/${BreathingProgression.sessionsPerLevel(session.exercise.id)} sessions to the next.")
                },
                style = NoopType.body, color = Palette.accent,
            )
        }
        Text(
            when (upload) {
                BreathingSession.Upload.NotConfigured -> l("Non envoyée : ajoute ta clé API intervals.icu dans les réglages.", "Not sent: add your intervals.icu API key in Settings.")
                BreathingSession.Upload.Sending -> l("Envoi vers intervals.icu…", "Sending to intervals.icu…")
                BreathingSession.Upload.Sent -> l("Envoyée sur intervals.icu", "Sent to intervals.icu")
                is BreathingSession.Upload.Failed -> l("L'envoi vers intervals.icu a échoué (${upload.reason}).", "Sending to intervals.icu failed (${upload.reason}).")
            },
            style = NoopType.caption, color = Palette.textSecondary,
        )
        if (upload is BreathingSession.Upload.Failed) {
            NoopButton(l("Réessayer", "Try again"), kind = NoopButtonKind.Secondary, fullWidth = true, onClick = session::retryUpload)
        }
    }
}

@Composable
private fun PartCard(name: String, p: BreathingSession.PartStats) {
    if (p.seconds == 0) return
    NoopCard(padding = 14.dp) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("$name · ${clock(p.seconds)}", style = NoopType.headline, color = Palette.textPrimary)
            val bits = listOfNotNull(
                p.avgHR?.let { l("FC moy. ", "Avg HR ") + "${Math.round(it)} bpm" },
                p.avgBreathsPerMin?.let { l("respiration ", "breathing ") + "%.1f/min".format(it) },
                p.rmssd?.let { "HRV ${Math.round(it)} ms" },
                p.avgCoherence?.let { l("cohérence ", "coherence ") + "${Math.round(it)}/100" },
            )
            Text(bits.joinToString(" · "), style = NoopType.caption, color = Palette.textSecondary)
        }
    }
}
