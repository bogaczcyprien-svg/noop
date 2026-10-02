#if os(iOS)
import SwiftUI
import StrandDesign

/// Settings for the morning sleep-recap notification (fork addition). Default OFF; posts a local,
/// once-per-day notification summarizing last night's phases/duration/efficiency/Charge as soon as
/// that night's data is computed. No server, no network.
struct SleepRecapSettingsView: View {
    @State private var enabled = SleepRecapNotifier.shared.isEnabled
    @State private var trendEnabled = TrendNotifier.shared.isEnabled
    @State private var nutritionEnabled = WorkoutNutritionNotifier.shared.isEnabled

    var body: some View {
        ScreenScaffold(
            title: "Résumé de nuit",
            subtitle: "Des notifications locales — rien n'est envoyé en dehors de l'appareil."
        ) {
            StrandCard(padding: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $enabled) {
                        Text("Notification du matin")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)
                    .onChange(of: enabled) { _, newValue in
                        SleepRecapNotifier.shared.setEnabled(newValue)
                    }

                    Text("Désactivé par défaut. Une fois activé, dès que la nuit précédente est calculée (après la synchro du bracelet), NOOP envoie une notification avec la durée, les phases (profond/REM/léger), l'efficacité, le Charge du jour, une suggestion d'heure de coucher pour ce soir, et — si le réveil intelligent est activé — si l'heure de réveil réglée est tombée en sommeil léger ou non (information seulement, l'heure du réveil ne change pas automatiquement). Une seule fois par jour.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            StrandCard(padding: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $trendEnabled) {
                        Text("Notification de tendance HRV")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)
                    .onChange(of: trendEnabled) { _, newValue in
                        TrendNotifier.shared.setEnabled(newValue)
                    }

                    Text("Désactivé par défaut. Prévient quand votre HRV est nettement au-dessus ou en-dessous de d'habitude depuis au moins 3 nuits de suite — une notification par tendance, pas une par jour. Distinct de l'alerte maladie, qui demande un motif plus précis sur plusieurs signaux.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            StrandCard(padding: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $nutritionEnabled) {
                        Text("Rappel nutrition après l'effort")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .tint(StrandPalette.accent)
                    .onChange(of: nutritionEnabled) { _, newValue in
                        WorkoutNutritionNotifier.shared.setEnabled(newValue)
                    }

                    Text("Désactivé par défaut. Une notification peu après la fin d'une séance détectée, pour penser à manger et vous hydrater dans l'heure qui suit — pas de journal alimentaire, juste un rappel de timing.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
#endif
