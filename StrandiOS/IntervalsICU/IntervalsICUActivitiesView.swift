#if os(iOS)
import SwiftUI
import StrandDesign
import WhoopStore

/// A dedicated list of every activity imported from intervals.icu — separate from the general
/// Workouts screen (which mixes every source together), so rides/sessions synced from intervals.icu
/// are easy to review on their own with their full detail. Fork addition; read-only, reuses the
/// already-imported `WorkoutRow` rows (`deviceId == "intervals-icu"`), no new storage.
struct IntervalsICUActivitiesView: View {
    @State private var activities: [WorkoutRow] = []
    @State private var loaded = false
    @State private var cachedStore: WhoopStore?

    var body: some View {
        ScreenScaffold(
            title: "Activités intervals.icu",
            subtitle: "Toutes vos séances importées depuis intervals.icu."
        ) {
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
                ForEach(activities.sorted(by: { $0.startTs > $1.startTs }), id: \.startTs) { activity in
                    activityCard(activity)
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
            }
        }
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
#endif
