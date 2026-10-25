#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// The Breathing tab (fork addition, iOS): connect a chest strap, pick an evidence-led exercise, run a
/// session (free breathing, then the guided part), and post it to intervals.icu. The older trainer with
/// the full technique catalogue stays one tap away under "More techniques".
struct BreathingTabView: View {
    @EnvironmentObject private var live: LiveState
    @StateObject private var strap = BreathingStrapLink()
    @ObservedObject private var intervals = IntervalsICUSettings.shared

    @AppStorage("noop.breathing.freeMinutes") private var freeMinutes = 10
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    @State private var nudgeOn = BedtimeBreathingNudge.shared.isEnabled
    @State private var detail: BreathingExercise?
    @State private var session: SessionHandle?
    @State private var showStrapPicker = false

    struct SessionHandle: Identifiable {
        let id = UUID()
        let model: BreathingSessionModel
    }

    private var cardOpacity: Double { max(0, min(1, Double(cardOpacityPercent) / 100)) }

    var body: some View {
        ScreenScaffold(title: "Breathing",
                       subtitle: "Exercises backed by research, guided by your heart.",
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                strapCard
                freeBreathingCard
                exercisesSection
                moreTechniquesLink
                nudgeCard
                intervalsCard
                Text("Breathing exercises are a wellness practice, not medical treatment. Stop if you feel dizzy.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            strap.reconnectLast()
            if nudgeOn { BedtimeBreathingNudge.shared.requestPermissionIfNeeded() }
        }
        .sheet(isPresented: $showStrapPicker, onDismiss: { strap.stopScan() }) {
            StrapPickerSheet(strap: strap) { showStrapPicker = false }
        }
        .sheet(item: $detail) { ex in
            ExerciseDetailSheet(exercise: ex, freeMinutes: freeMinutes) {
                detail = nil
                startSession(ex)
            }
        }
        .fullScreenCover(item: $session) { handle in
            BreathingSessionView(model: handle.model) { session = nil }
        }
    }

    private func startSession(_ ex: BreathingExercise) {
        let model = BreathingSessionModel(exercise: ex, freeSeconds: freeMinutes * 60, strap: strap, live: live)
        session = SessionHandle(model: model)
        BedtimeBreathingNudge.shared.noteSessionDone()
        model.start()
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoopPanelSurface(cornerRadius: 22, surfaceOpacity: cardOpacity))
    }

    // MARK: - Strap

    private var strapCard: some View {
        card {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Chest strap").strandOverline()
                HStack(alignment: .center, spacing: NoopMetrics.gap) {
                    Image(systemName: strap.isConnected ? "heart.fill" : "heart")
                        .font(StrandFont.title2)
                        .foregroundStyle(strap.isConnected ? StrandPalette.liquidHeart : StrandPalette.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(strapTitle).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text(strapCaption).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let hr = strap.heartRate, strap.isConnected {
                        Text("\(hr)").font(StrandFont.number(28)).foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                if strap.isConnected {
                    NoopButton("Disconnect", systemImage: "xmark", kind: .secondary, fullWidth: true) { strap.disconnect() }
                } else {
                    NoopButton("Find my strap", systemImage: "dot.radiowaves.left.and.right", kind: .primary, fullWidth: true) {
                        strap.scan()
                        showStrapPicker = true
                    }
                }
            }
        }
    }

    private var strapTitle: String {
        switch strap.state {
        case .connected: return strap.strapName ?? String(localized: "Chest strap")
        case .connecting: return String(localized: "Connecting…")
        case .scanning: return String(localized: "Searching…")
        case .bluetoothOff: return String(localized: "Bluetooth is off")
        case .idle, .disconnected: return String(localized: "No strap connected")
        }
    }

    private var strapCaption: String {
        strap.isConnected
            ? String(localized: "Beat-to-beat data: breathing rate, HRV and coherence are measured live.")
            : String(localized: "Without a strap, the WHOOP's heart rate is used; it is less precise beat to beat.")
    }

    // MARK: - Free breathing

    private var freeBreathingCard: some View {
        card {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Before the exercise").strandOverline()
                Text("Free breathing first: breathe normally while your baseline is recorded, then the guided exercise starts.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                SegmentedPillControl([0, 5, 10], selection: $freeMinutes, fillsAvailableWidth: true) { m in
                    m == 0 ? String(localized: "None") : String(localized: "\(m) min")
                }
            }
        }
    }

    // MARK: - Exercises

    private var exercisesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Exercises").strandOverline()
            ForEach(BreathingScienceCatalog.all) { ex in
                Button { detail = ex } label: {
                    card {
                        HStack(spacing: NoopMetrics.gap) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(verbatim: BreathingL10n.text(ex.title)).font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(verbatim: BreathingL10n.text(ex.subtitle)).font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                if let first = ex.benefits.first {
                                    Label(BreathingL10n.text(first), systemImage: "checkmark")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.statusPositive)
                                }
                                if ex.id == BreathingScienceCatalog.resonanceId, let bpm = BiofeedbackPrefs.lockedPace {
                                    Text("Your pace: \(String(format: "%.1f", bpm)) breaths/min")
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
                .buttonStyle(StrandPressableButtonStyle())
            }
        }
    }

    private var moreTechniquesLink: some View {
        NavigationLink {
            BreathingView()
        } label: {
            card {
                HStack {
                    Text("More techniques").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(StrandPressableButtonStyle())
    }

    // MARK: - Settings cards

    private var nudgeCard: some View {
        card {
            Toggle(isOn: Binding(get: { nudgeOn }, set: { on in
                nudgeOn = on
                BedtimeBreathingNudge.shared.setEnabled(on)
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bedtime reminder").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text("Between 9 and 11 pm, when the WHOOP sees you still and calm, a notification suggests cardiac coherence.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(StrandPalette.accent)
        }
    }

    private var intervalsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 4) {
                Text("intervals.icu").strandOverline()
                Text(intervals.hasApiKey
                     ? String(localized: "Each session is sent as an activity: heart rate, breathing rate and every heartbeat.")
                     : String(localized: "Add your intervals.icu API key in Settings to send each session as an activity."))
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Scan results for the chest strap.
private struct StrapPickerSheet: View {
    @ObservedObject var strap: BreathingStrapLink
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if strap.state == .bluetoothOff {
                    Text("Turn Bluetooth on to find your strap.").foregroundStyle(StrandPalette.textSecondary)
                } else if strap.found.isEmpty {
                    HStack(spacing: NoopMetrics.gap) {
                        ProgressView()
                        Text("Put the strap on (wet the sensors) and keep the phone close.")
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                ForEach(strap.found) { s in
                    Button {
                        strap.connect(s.id)
                        onDone()
                    } label: {
                        HStack {
                            Text(s.name).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text("\(s.rssi) dBm").font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                }
            }
            .navigationTitle("Choose a strap")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onDone() } }
            }
        }
    }
}

/// How to do it, what the research says, and the start button.
private struct ExerciseDetailSheet: View {
    let exercise: BreathingExercise
    let freeMinutes: Int
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    Text(verbatim: BreathingL10n.text(exercise.subtitle)).font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    if !exercise.benefits.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What it does for you").strandOverline()
                            ForEach(exercise.benefits, id: \.self) { b in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(StrandPalette.statusPositive)
                                    Text(verbatim: BreathingL10n.text(b)).font(StrandFont.body)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    section("How to do it", exercise.howTo)
                    section("What the research says", exercise.evidence)
                    if let c = exercise.caution {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StrandPalette.statusWarning)
                            Text(verbatim: BreathingL10n.text(c)).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text(freeMinutes > 0
                         ? String(localized: "\(freeMinutes) min of free breathing, then the exercise.")
                         : String(localized: "The exercise starts right away."))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    NoopButton("Start", systemImage: "play.fill", kind: .primary, fullWidth: true) { onStart() }
                }
                .padding(NoopMetrics.screenPadding)
            }
            .navigationTitle(BreathingL10n.text(exercise.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func section(_ title: LocalizedStringKey, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).strandOverline()
            Text(verbatim: BreathingL10n.text(body)).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif

#if os(iOS)
/// Looks up catalogue text (exercise titles, how-tos, evidence) by its English source. The bundle lookup
/// does no format parsing, so a literal "%" in the text ("+24%") can never be read as a specifier.
enum BreathingL10n {
    static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
#endif
