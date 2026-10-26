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
    @StateObject private var core = CoreTempLink()
    @ObservedObject private var intervals = IntervalsICUSettings.shared

    @AppStorage("noop.breathing.freeMinutes") private var freeMinutes = 10
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    @State private var nudgeOn = BedtimeBreathingNudge.shared.isEnabled
    @State private var detail: BreathingExercise?
    @State private var session: SessionHandle?
    @State private var showStrapPicker = false
    @State private var history: [BreathingHistory.Entry] = []
    @State private var showCorePicker = false

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
                coreCard
                progressCard
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
            history = BreathingHistoryStore.load()
            core.reconnectLast()
            if nudgeOn { BedtimeBreathingNudge.shared.requestPermissionIfNeeded() }
        }
        .sheet(isPresented: $showStrapPicker, onDismiss: { strap.stopScan() }) {
            SensorPickerSheet(title: "Choose a strap", found: strap.found,
                              bluetoothOff: strap.state == .bluetoothOff,
                              offHint: "Turn Bluetooth on to find your strap.",
                              searchHint: "Put the strap on (wet the sensors) and keep the phone close.",
                              onPick: { strap.connect($0) }) { showStrapPicker = false }
        }
        .sheet(isPresented: $showCorePicker, onDismiss: { core.stopScan() }) {
            SensorPickerSheet(title: "Choose a CORE", found: core.found,
                              bluetoothOff: core.state == .bluetoothOff,
                              offHint: "Turn Bluetooth on to find your CORE.",
                              searchHint: "Wear the CORE and close the CORE app, which can hold the sensor's only connection.",
                              onPick: { core.connect($0) }) { showCorePicker = false }
        }
        .sheet(item: $detail) { ex in
            ExerciseDetailSheet(exercise: ex, freeMinutes: freeMinutes) {
                detail = nil
                startSession(ex)
            }
        }
        .fullScreenCover(item: $session) { handle in
            BreathingSessionView(model: handle.model) {
                session = nil
                history = BreathingHistoryStore.load()
            }
        }
    }

    private func startSession(_ ex: BreathingExercise) {
        let model = BreathingSessionModel(exercise: BreathingLevelStore.current(ex), freeSeconds: freeMinutes * 60,
                                          strap: strap, core: core, live: live)
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

    // MARK: - Progress

    private var progressCard: some View {
        card {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("Your progress").strandOverline()
                if history.isEmpty {
                    Text("Do a few sessions to see your progress here.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: NoopMetrics.gap) {
                        StatTile(label: "Last 7 days", value: "\(BreathingHistory.sessionsLast7Days(history, now: Date()))",
                                 caption: String(localized: "sessions"))
                        StatTile(label: "Streak",
                                 value: "\(BreathingHistory.streakDays(history, now: Date(), calendar: .current))",
                                 caption: String(localized: "days"))
                    }
                    let points = history.suffix(30).compactMap { e in
                        e.avgCoherence.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval(e.ts)), value: $0) }
                    }
                    if points.count >= 2 {
                        Text("Coherence per session").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        TrendChart(points: points, gradient: StrandPalette.recoveryGradient, valueRange: 0...100,
                                   height: 140, accessibilityLabel: String(localized: "Coherence per session"))
                    }
                    if let t = BreathingHistory.trend(history, { $0.avgCoherence }) {
                        progressLine(String(localized: "Coherence, last 7 sessions: \(Int(t.recent.rounded()))/100 (\(signed(t.recent - t.previous)) vs the 7 before)."))
                    }
                    if let t = BreathingHistory.trend(history, { $0.hrChange }) {
                        progressLine(String(localized: "Heart rate during the exercise, last 7 sessions: \(signed(t.recent)) bpm vs free breathing (the 7 before: \(signed(t.previous)))."))
                    } else if history.count < 2 * BreathingHistory.trendWindow {
                        Text("The trend shows after \(2 * BreathingHistory.trendWindow) sessions.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }

    // MARK: - CORE

    private var coreCard: some View {
        card {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text("CORE sensor").strandOverline()
                HStack(alignment: .center, spacing: NoopMetrics.gap) {
                    Image(systemName: "thermometer.medium")
                        .font(StrandFont.title2)
                        .foregroundStyle(core.isConnected ? StrandPalette.accent : StrandPalette.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(coreTitle).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("Internal body temperature, shown during the exercise and sent with the activity.")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let c = core.currentCoreC() {
                        Text(c.formatted(.number.precision(.fractionLength(1))))
                            .font(StrandFont.number(28)).foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                if core.isConnected {
                    NoopButton("Disconnect", systemImage: "xmark", kind: .secondary, fullWidth: true) { core.disconnect() }
                } else {
                    NoopButton("Find my CORE", systemImage: "dot.radiowaves.left.and.right", kind: .primary, fullWidth: true) {
                        core.scan()
                        showCorePicker = true
                    }
                }
            }
        }
    }

    private func progressLine(_ text: String) -> some View {
        Text(verbatim: text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "+8" / "−3" / "0", whole numbers.
    private func signed(_ v: Double) -> String {
        let r = Int(v.rounded())
        return r > 0 ? "+\(r)" : r < 0 ? "−\(-r)" : "0"
    }

    private var coreTitle: String {
        switch core.state {
        case .connected:
            return core.coreC == nil
                ? String(localized: "Connected, waiting for a reading…")
                : (core.sensorName ?? "CORE")
        case .connecting: return String(localized: "Connecting…")
        case .scanning: return String(localized: "Searching…")
        case .bluetoothOff: return String(localized: "Bluetooth is off")
        case .idle, .disconnected: return String(localized: "No CORE connected")
        }
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
                                if BreathingProgression.isProgressive(ex.id) {
                                    let level = BreathingLevelStore.state(ex.id).level
                                    Text(verbatim: String(localized: "Level \(level)/\(BreathingProgression.maxLevel(ex.id))")
                                         + (BreathingLevelStore.levelDetail(ex.id, level: level).map { " · " + $0 } ?? ""))
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
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
                    Text("Between 9 and 11 pm, when the WHOOP sees you lying still and not yet asleep, a notification suggests cardiac coherence.")
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

/// Scan results for a Breathing-tab sensor (chest strap or CORE).
private struct SensorPickerSheet: View {
    let title: LocalizedStringKey
    let found: [BreathingSensorFound]
    let bluetoothOff: Bool
    let offHint: LocalizedStringKey
    let searchHint: LocalizedStringKey
    let onPick: (UUID) -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if bluetoothOff {
                    Text(offHint).foregroundStyle(StrandPalette.textSecondary)
                } else if found.isEmpty {
                    HStack(spacing: NoopMetrics.gap) {
                        ProgressView()
                        Text(searchHint).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                ForEach(found) { s in
                    Button {
                        onPick(s.id)
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
            .navigationTitle(title)
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
    /// Training level, re-read after a step down.
    @State private var levelState: BreathingProgression.State?

    private var level: BreathingProgression.State { levelState ?? BreathingLevelStore.state(exercise.id) }

    /// Level, what it asks for, how far the next one is, and the "too hard" step down.
    private var levelCard: some View {
        let id = exercise.id
        let max = BreathingProgression.maxLevel(id)
        let left = BreathingProgression.sessionsPerLevel(id) - level.completions
        return VStack(alignment: .leading, spacing: 8) {
            Text("Your level").strandOverline()
            Text(verbatim: String(localized: "Level \(level.level) of \(max)"))
                .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            if let detail = BreathingLevelStore.levelDetail(id, level: level.level) {
                Text(verbatim: detail).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(verbatim: level.level >= max
                 ? String(localized: "Top level reached. Keep it up to hold your gains.")
                 : String(localized: "\(left) more full sessions to reach level \(level.level + 1)."))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            if level.level > 1 {
                NoopButton("Too hard? One level down", systemImage: "arrow.down", kind: .tertiary) {
                    let down = BreathingProgression.stepDown(level, id: id)
                    BreathingLevelStore.save(down, id)
                    levelState = down
                }
            }
        }
    }

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
                    if BreathingProgression.isProgressive(exercise.id) { levelCard }
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

#if os(iOS)
/// Per-exercise training level (`BreathingProgression.State`), kept in UserDefaults on this phone.
enum BreathingLevelStore {
    private static func key(_ id: String, _ part: String) -> String { "noop.breathing.\(part).\(id)" }

    static func state(_ id: String) -> BreathingProgression.State {
        let d = UserDefaults.standard
        let level = d.object(forKey: key(id, "level")) as? Int ?? 1
        return .init(level: level, completions: d.integer(forKey: key(id, "done")))
    }

    static func save(_ s: BreathingProgression.State, _ id: String) {
        UserDefaults.standard.set(s.level, forKey: key(id, "level"))
        UserDefaults.standard.set(s.completions, forKey: key(id, "done"))
    }

    /// The exercise at its current level.
    static func current(_ base: BreathingExercise) -> BreathingExercise {
        BreathingProgression.exercise(base, level: state(base.id).level)
    }

    /// What the current level asks for, in one line.
    static func levelDetail(_ id: String, level: Int) -> String? {
        switch id {
        case BreathingScienceCatalog.co2Id:
            return String(localized: "Hold \(BreathingProgression.co2HoldSeconds(level: level)) s after the exhale")
        case BreathingScienceCatalog.breathHoldsId:
            let h = BreathingProgression.breathHolds(level: level)
            return String(localized: "\(h.rounds) holds, up to \(h.maxHoldSeconds / 60) min \(h.maxHoldSeconds % 60) s each")
        case BreathingScienceCatalog.respiratoryMuscleId:
            return String(localized: "\(BreathingProgression.muscleBreaths(level: level)) strong breaths")
        default:
            return nil
        }
    }
}
#endif
