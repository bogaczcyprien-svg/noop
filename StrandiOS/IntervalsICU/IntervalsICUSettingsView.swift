#if os(iOS)
import SwiftUI
import StrandDesign

/// Imports cycling (and other) activities from intervals.icu directly into NOOP's own Workouts —
/// useful for sessions ridden without the strap on (e.g. cycling), where WHOOP never saw the HR.
/// Read-only against intervals.icu's public API; nothing is written back there.
struct IntervalsICUSettingsView: View {
    @ObservedObject private var settings = IntervalsICUSettings.shared
    @ObservedObject private var runner = IntervalsICURunner.shared

    @State private var athleteIdDraft: String = ""
    @State private var apiKeyDraft: String = ""
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, success(count: Int), failure(String)
    }

    var body: some View {
        ScreenScaffold(
            title: "intervals.icu",
            subtitle: "Importe vos séances (dont celles sans bracelet, ex. vélo) depuis intervals.icu."
        ) {
            configCard
            statusCard
        }
        .onAppear { athleteIdDraft = settings.athleteId }
    }

    private var configCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "figure.outdoor.cycle")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Connexion")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Athlete ID").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    TextField("0 (vous-même)", text: $athleteIdDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)
                        .font(StrandFont.subhead)
                        .onSubmit { settings.setAthleteId(athleteIdDraft) }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Clé API").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    SecureField(settings.hasApiKey ? "Clé enregistrée — entrez pour remplacer" : "Depuis intervals.icu → Settings → Developer Settings", text: $apiKeyDraft)
                        .font(StrandFont.subhead)
                        .onSubmit {
                            guard !apiKeyDraft.isEmpty else { return }
                            settings.setApiKey(apiKeyDraft)
                            apiKeyDraft = ""
                        }
                }

                HStack(spacing: 12) {
                    Button {
                        settings.setAthleteId(athleteIdDraft)
                        Task { await runTest() }
                    } label: {
                        if testState == .testing { ProgressView() } else { Text("Tester la connexion") }
                    }
                    .disabled(!settings.hasApiKey && apiKeyDraft.isEmpty || testState == .testing)

                    Button("Importer maintenant") {
                        settings.setAthleteId(athleteIdDraft)
                        Task { await runner.importRecent() }
                    }
                    .disabled(!settings.hasApiKey || runner.isRunning)
                }
                .font(StrandFont.subhead)

                testStateView
            }
        }
    }

    @ViewBuilder
    private var testStateView: some View {
        switch testState {
        case .idle, .testing:
            EmptyView()
        case .success(let count):
            Label("Connecté — \(count) activité(s) trouvée(s) aujourd'hui", systemImage: "checkmark.circle.fill")
                .font(StrandFont.caption)
                .foregroundStyle(.green)
        case .failure(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(StrandFont.caption)
                .foregroundStyle(.orange)
        }
    }

    private var statusCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Dernier import").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text(runner.lastResult ?? "Rien importé pour l'instant.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Les séances importées apparaissent dans Workouts avec la source « intervals.icu ». NOOP recalcule son propre Strain à partir de ses propres données — un import n'y contribue pas.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runTest() async {
        testState = .testing
        guard let key = settings.hasApiKey ? settings.apiKey() : (apiKeyDraft.isEmpty ? nil : apiKeyDraft) else {
            testState = .failure("pas de clé API")
            return
        }
        if !apiKeyDraft.isEmpty { settings.setApiKey(apiKeyDraft); apiKeyDraft = "" }
        let client = IntervalsICUClient(athleteId: settings.athleteId, apiKey: key)
        switch await client.testConnection() {
        case .success(let count): testState = .success(count: count)
        case .failure(let reason): testState = .failure(reason)
        }
    }
}
#endif
