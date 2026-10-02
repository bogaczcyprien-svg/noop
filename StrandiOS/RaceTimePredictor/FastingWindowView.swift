#if os(iOS)
import SwiftUI
import StrandDesign

/// Logs an overnight fasting window (last meal → first meal) as a numeric Journal entry — "Fasting
/// window (hours)" — so it flows through the SAME correlation pipeline (DoseResponseEngine / Insights)
/// every other numeric journal item already does, rather than a parallel tracking system. Fork
/// addition: a 2-field logger, not a food diary.
struct FastingWindowView: View {
    @EnvironmentObject var repo: Repository

    static let journalQuestion = "Fasting window (hours)"

    @State private var lastMeal = Calendar.current.date(
        bySettingHour: 20, minute: 0, second: 0, of: Date().addingTimeInterval(-86_400)) ?? Date()
    @State private var firstMeal = Calendar.current.date(
        bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var saved = false

    private var hours: Double {
        max(0, firstMeal.timeIntervalSince(lastMeal) / 3_600)
    }

    var body: some View {
        ScreenScaffold(
            title: "Fenêtre de jeûne",
            subtitle: "Dernier repas d'hier soir → premier repas aujourd'hui."
        ) {
            StrandCard(padding: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    DatePicker("Dernier repas (hier)", selection: $lastMeal, displayedComponents: .hourAndMinute)
                        .font(StrandFont.subhead)
                    DatePicker("Premier repas (aujourd'hui)", selection: $firstMeal, displayedComponents: .hourAndMinute)
                        .font(StrandFont.subhead)

                    HStack {
                        Text("Durée du jeûne")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        Text(String(format: "%.1fh", hours))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.accent)
                    }

                    Button {
                        Task {
                            await repo.saveJournalNumeric(
                                day: Repository.localDayKey(Date()),
                                question: Self.journalQuestion,
                                value: hours
                            )
                            saved = true
                        }
                    } label: {
                        Text(saved ? "Enregistré ✓" : "Enregistrer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(StrandPalette.accent)

                    Text("Enregistré comme une entrée de Journal numérique standard — visible et corrélable à votre Charge/sommeil dans Insights, comme vos autres entrées (café, alcool…).")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
#endif
