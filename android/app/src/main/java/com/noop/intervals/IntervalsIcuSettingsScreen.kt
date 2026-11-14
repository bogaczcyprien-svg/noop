package com.noop.intervals

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.CloudUpload
import androidx.compose.material.icons.filled.Key
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.noop.ui.AppViewModel
import com.noop.ui.NoopButton
import com.noop.ui.NoopButtonKind
import com.noop.ui.NoopType
import com.noop.ui.Palette
import com.noop.ui.ScreenScaffold
import com.noop.ui.SettingsCard
import com.noop.ui.SettingsToggleRow
import kotlinx.coroutines.launch

/** FORK: intervals.icu connection, import and wellness-push settings. Twin of the fork iOS settings view. */
@Composable
fun IntervalsIcuSettingsScreen(vm: AppViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var athleteId by remember { mutableStateOf(IntervalsIcuSettings.athleteId(context).takeIf { it != "0" } ?: "") }
    var apiKeyDraft by remember { mutableStateOf("") }
    var hasKey by remember { mutableStateOf(IntervalsIcuSettings.hasApiKey(context)) }
    var testMessage by remember { mutableStateOf<String?>(null) }
    var testing by remember { mutableStateOf(false) }
    var pushEnabled by remember { mutableStateOf(IntervalsIcuSettings.pushEnabled(context)) }
    var fields by remember { mutableStateOf(IntervalsIcuSettings.pushFields(context)) }
    val running by IntervalsIcuRunner.running.collectAsState()
    val lastResult by IntervalsIcuRunner.lastResult.collectAsState()
    val lastPush by IntervalsIcuRunner.lastPushResult.collectAsState()

    ScreenScaffold(title = "intervals.icu", subtitle = "Séances, entraînements prévus et envoi de vos nuits") {
        SettingsCard(
            icon = Icons.Filled.Key,
            title = "Connexion",
            blurb = "Clé API depuis intervals.icu → Settings → Developer Settings. Laissez l'Athlete ID vide pour votre propre compte.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                IcuTextField(athleteId, { athleteId = it }, "Athlete ID (vide = vous-même)", secret = false)
                IcuTextField(
                    apiKeyDraft, { apiKeyDraft = it },
                    if (hasKey) "Clé enregistrée — entrez-en une pour la remplacer" else "Clé API",
                    secret = true,
                )
                NoopButton(
                    text = "Enregistrer",
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    onClick = {
                        IntervalsIcuSettings.setAthleteId(context, athleteId)
                        if (apiKeyDraft.isNotBlank()) IntervalsIcuSettings.setApiKey(context, apiKeyDraft)
                        apiKeyDraft = ""
                        hasKey = IntervalsIcuSettings.hasApiKey(context)
                        testMessage = "Enregistré"
                    },
                )
                NoopButton(
                    text = if (testing) "Test en cours…" else "Tester la connexion",
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = hasKey && !testing,
                    onClick = {
                        val client = IntervalsIcuSettings.client(context) ?: return@NoopButton
                        testing = true
                        scope.launch {
                            testMessage = client.testConnection().fold(
                                onSuccess = { "Connecté — $it séance(s) aujourd'hui" },
                                onFailure = { "Échec : ${it.message ?: it.javaClass.simpleName}" },
                            )
                            testing = false
                        }
                    },
                )
                testMessage?.let { Text(it, style = NoopType.footnote, color = Palette.textSecondary) }
            }
        }

        SettingsCard(
            icon = Icons.Filled.CloudSync,
            title = "Import des séances",
            blurb = "Les séances intervals.icu des 30 derniers jours arrivent dans NOOP avec leur tracé cardiaque, à chaque synchro du bracelet. Leurs calories remplacent l'estimation du cœur sur la durée de la séance.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                NoopButton(
                    text = if (running) "Import en cours…" else "Importer maintenant",
                    kind = NoopButtonKind.Secondary,
                    fullWidth = true,
                    enabled = hasKey && !running,
                    onClick = { scope.launch { IntervalsIcuRunner.importRecent(context, vm.repo) } },
                )
                Text(
                    "Dernier import : ${lastResult ?: "rien importé pour l'instant"}",
                    style = NoopType.footnote, color = Palette.textSecondary,
                )
            }
        }

        SettingsCard(
            icon = Icons.Filled.CloudUpload,
            title = "Envoyer mes nuits",
            blurb = "Désactivé par défaut. Une fois activé, après chaque synchro NOOP envoie le résumé déjà calculé de votre nuit vers votre fiche bien-être intervals.icu du jour.",
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SettingsToggleRow(
                    title = "Envoyer mes nuits vers intervals.icu",
                    detail = "Rien n'est relu depuis intervals.icu pour cet envoi.",
                    checked = pushEnabled,
                    onCheckedChange = {
                        pushEnabled = it
                        IntervalsIcuSettings.setPushEnabled(context, it)
                    },
                )
                if (pushEnabled) {
                    for ((field, label) in FIELD_LABELS) {
                        SettingsToggleRow(
                            title = label,
                            detail = "",
                            checked = field in fields,
                            onCheckedChange = { on ->
                                IntervalsIcuSettings.setPushField(context, field, on)
                                fields = IntervalsIcuSettings.pushFields(context)
                            },
                        )
                    }
                    NoopButton(
                        text = "Envoyer maintenant",
                        kind = NoopButtonKind.Secondary,
                        fullWidth = true,
                        enabled = hasKey,
                        onClick = {
                            scope.launch { IntervalsIcuRunner.pushLastNightIfEnabled(context, vm.repo, vm.activeStrapId) }
                        },
                    )
                    Text(
                        "Dernier envoi : ${lastPush ?: "pas encore tenté depuis l'activation"}",
                        style = NoopType.footnote, color = Palette.textSecondary,
                    )
                }
            }
        }
    }
}

private val FIELD_LABELS = listOf(
    IntervalsIcuSettings.WellnessField.CHARGE to "Réparation (score NOOP)",
    IntervalsIcuSettings.WellnessField.HRV to "HRV",
    IntervalsIcuSettings.WellnessField.RESTING_HR to "FC repos",
    IntervalsIcuSettings.WellnessField.SLEEP to "Sommeil (durée et score)",
    IntervalsIcuSettings.WellnessField.WEIGHT to "Poids",
    IntervalsIcuSettings.WellnessField.STEPS to "Pas",
)

@Composable
private fun IcuTextField(value: String, onValueChange: (String) -> Unit, label: String, secret: Boolean) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        singleLine = true,
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        textStyle = NoopType.mono(13f),
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(14.dp),
        colors = OutlinedTextFieldDefaults.colors(
            focusedTextColor = Palette.textPrimary,
            unfocusedTextColor = Palette.textPrimary,
            focusedBorderColor = Palette.accent,
            unfocusedBorderColor = Palette.hairline,
            cursorColor = Palette.accent,
            focusedContainerColor = Palette.surfaceInset,
            unfocusedContainerColor = Palette.surfaceInset,
        ),
    )
}
