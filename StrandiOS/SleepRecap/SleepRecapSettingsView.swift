#if os(iOS)
import SwiftUI
import StrandDesign

/// Settings for the morning sleep-recap notification (fork addition). Default OFF; posts a local,
/// once-per-day notification summarizing last night's phases/duration/efficiency/Charge as soon as
/// that night's data is computed. No server, no network.
struct SleepRecapSettingsView: View {
    @State private var enabled = SleepRecapNotifier.shared.isEnabled

    var body: some View {
        ScreenScaffold(
            title: "Résumé de nuit",
            subtitle: "Une notification locale chaque matin avec le résumé de votre nuit."
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

                    Text("Désactivé par défaut. Une fois activé, dès que la nuit précédente est calculée (après la synchro du bracelet), NOOP envoie une notification avec la durée, les phases (profond/REM/léger), l'efficacité et le Charge du jour — une seule fois par jour. Rien n'est envoyé en dehors de l'appareil.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
#endif
