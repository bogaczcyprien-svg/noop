#if os(iOS)
import SwiftUI
import MarkdownUI
import StrandDesign
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// A list of every activity imported from intervals.icu — separate from the general Workouts list
/// (which mixes every source together), so rides/sessions synced from intervals.icu are easy to
/// review with their full detail. Fork addition; read-only, reuses the already-imported `WorkoutRow`
/// rows (`deviceId == "intervals-icu"`), no new storage.
///
/// Embedded directly on Today (below "Your Cards") rather than tucked under More — the user wants it
/// immediately visible, not a tap away. Plain content, no `ScreenScaffold`: the caller (Today's
/// reorderable section list) owns the page chrome.
///
/// Also offers a per-activity AI debrief (`AICoachEngine.headlessAnswer`, the SAME bring-your-own-key
/// Coach the rest of the app uses — no second key/consent surface): a short text breakdown of the
/// aerobic/anaerobic contribution, built from a Karvonen %HRR time split over the real per-sample HR
/// `IntervalsICUImporter` backfilled for this activity (see `WorkoutDebrief`).
struct IntervalsICUActivitiesSection: View {
    @EnvironmentObject var coach: AICoachEngine
    @EnvironmentObject var profile: ProfileStore
    @State private var activities: [WorkoutRow] = []
    @State private var loaded = false
    @State private var cachedStore: WhoopStore?
    /// Debrief state keyed by `activity.startTs` (unique per activity). A nil-less dictionary lookup
    /// (`debriefText[ts]`) doubles as "not yet requested" vs. "request returned this text".
    @State private var debriefText: [Int: String] = [:]
    @State private var debriefFailed: Set<Int> = []
    @State private var debriefLoading: Set<Int> = []

    /// Cap the number of activities shown — the Today embedding passes a small number so it doesn't
    /// dump a full season of rides onto the home screen; nil (the "See all" destination) shows every
    /// activity. When capped and more exist, a trailing link opens the full, uncapped list.
    var limit: Int? = nil

    private var sortedActivities: [WorkoutRow] {
        activities.sorted(by: { $0.startTs > $1.startTs })
    }
    private var visibleActivities: [WorkoutRow] {
        guard let limit else { return sortedActivities }
        return Array(sortedActivities.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Activités intervals.icu", overline: "intervals.icu")
            if activities.isEmpty {
                StrandCard(padding: 20) {
                    Text(loaded
                         ? "Aucune activité importée pour l'instant. Utilisez \"Importer maintenant\" dans les réglages intervals.icu."
                         : "Chargement…")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(visibleActivities, id: \.startTs) { activity in
                    activityCard(activity)
                }
                if let limit, sortedActivities.count > limit {
                    NavigationLink {
                        IntervalsICUActivitiesScreen()
                    } label: {
                        StrandCard(padding: 16) {
                            HStack {
                                Text("Voir toutes mes activités (\(sortedActivities.count))")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.accent)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { await load() }
    }

    private func activityCard(_ activity: WorkoutRow) -> some View {
        StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activity.notes ?? activity.sport)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(dateString(activity.startTs))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    Image(systemName: sportIcon(activity.sport))
                        .foregroundStyle(StrandPalette.accent)
                }

                HStack(spacing: 16) {
                    if let duration = activity.durationS {
                        statPair("Durée", formatDuration(duration))
                    }
                    if let distance = activity.distanceM {
                        statPair("Distance", String(format: "%.1f km", distance / 1_000))
                    }
                    if let avgHr = activity.avgHr {
                        statPair("FC moy.", "\(avgHr) bpm")
                    }
                    if let maxHr = activity.maxHr {
                        statPair("FC max", "\(maxHr) bpm")
                    }
                    if let kcal = activity.energyKcal {
                        statPair("Calories", "\(Int(kcal.rounded())) kcal")
                    }
                }

                debriefSection(activity)
            }
        }
    }

    @ViewBuilder
    private func debriefSection(_ activity: WorkoutRow) -> some View {
        let ts = activity.startTs
        Divider().padding(.vertical, 2)
        if let text = debriefText[ts] {
            Markdown(text).markdownTheme(.strand)
        } else if debriefLoading.contains(ts) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("L'IA débrief la séance…")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        } else {
            Button {
                Task { await debrief(activity) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                    Text("Débriefer avec l'IA")
                }
                .font(StrandFont.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.accent)
            if debriefFailed.contains(ts) {
                Text("Configure ta clé API dans Réglages > Coach pour utiliser le débrief IA.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// Runs the AI debrief for one activity: pulls the real per-sample HR backfilled for its time
    /// window, folds it into a Karvonen %HRR zone split (`WorkoutDebrief.zoneBreakdown`), builds the
    /// prompt, and hands it to the SAME Coach engine every other AI surface in the app uses
    /// (`AICoachEngine.headlessAnswer`) — no second key/consent flow for this one screen.
    @MainActor
    private func debrief(_ activity: WorkoutRow) async {
        let ts = activity.startTs
        debriefLoading.insert(ts)
        debriefFailed.remove(ts)
        defer { debriefLoading.remove(ts) }

        var hr: [HRSample] = []
        if let s = await store() {
            hr = (try? await s.hrSamples(
                deviceId: IntervalsICUImporter.deviceId, from: activity.startTs, to: activity.endTs, limit: 8_000
            )) ?? []
        }
        let maxHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
        let zones = maxHR.flatMap {
            WorkoutDebrief.zoneBreakdown(hr: hr, restingHR: StrainScorer.defaultRestingHR, maxHR: $0)
        }
        let prompt = WorkoutDebrief.prompt(activity: activity, zones: zones)

        guard let reply = await coach.headlessAnswer(prompt) else {
            debriefFailed.insert(ts)
            return
        }
        debriefText[ts] = reply
    }

    private func statPair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(StrandPalette.textTertiary)
            Text(value).font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func sportIcon(_ sport: String) -> String {
        switch sport.lowercased() {
        case let s where s.contains("ride") || s.contains("bike") || s.contains("cycl"):
            return "figure.outdoor.cycle"
        case let s where s.contains("run"):
            return "figure.run"
        case let s where s.contains("swim"):
            return "figure.pool.swim"
        default:
            return "figure.mixed.cardio"
        }
    }

    private func dateString(_ ts: Int) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3_600, m = (total % 3_600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m) min"
    }

    private func load() async {
        guard let store = await store() else { loaded = true; return }
        let now = Int(Date().timeIntervalSince1970)
        activities = (try? await store.workouts(
            deviceId: IntervalsICUImporter.deviceId, from: now - 365 * 86_400, to: now, limit: 500
        )) ?? []
        loaded = true
    }

    private func store() async -> WhoopStore? {
        if let cachedStore { return cachedStore }
        guard let path = try? StorePaths.defaultDatabasePath(),
              let opened = try? await WhoopStore(path: path)
        else { return nil }
        cachedStore = opened
        return opened
    }
}

/// The full, uncapped activity list — reached via the Today section's "See all" link when there are
/// more activities than its cap shows. Fork addition.
struct IntervalsICUActivitiesScreen: View {
    var body: some View {
        ScreenScaffold(
            title: "Activités intervals.icu",
            subtitle: "Toutes vos séances importées depuis intervals.icu."
        ) {
            IntervalsICUActivitiesSection()
        }
    }
}
#endif
