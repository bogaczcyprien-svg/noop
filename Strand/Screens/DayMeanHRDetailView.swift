import SwiftUI
import StrandDesign

// MARK: - Whole-day mean HR detail (FORK-ONLY, not ported to Android)
//
// Opened by tapping the Today "Avg HR (24h)" Key Metric tile. A custom screen rather than the generic
// MetricExplorerView/MetricDetailView machinery, since the ask was specifically to show the NIGHT-only
// figure nested inside this one metric's detail, not as its own separate browsable catalog entry.
//
// Both series read via `Repository.exploreSeries(key:source:)` with the "my-whoop" sentinel — the
// same read path `spo2_candidate`/`skin_temp`/`resp_rate` already use for a computed-only ("-noop")
// metricSeries key, so this needs no new Repository plumbing.
struct DayMeanHRDetailView: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    private static let historyDays = 30

    @State private var dayPoints: [TrendPoint] = []
    @State private var nightPoints: [TrendPoint] = []
    @State private var loaded = false

    private var todayDayMean: Double? { dayPoints.last?.value }
    private var todayNightMean: Double? { nightPoints.last?.value }

    var body: some View {
        ScreenScaffold(title: "Avg HR (24h)",
                       subtitle: "Whole day, including the night.",
                       onRefresh: { await load() },
                       topBackground: liquidScaffoldSky()) {
            headlineCard
            if loaded {
                trendCard(title: "Whole day", points: dayPoints, tint: StrandPalette.metricRose)
                trendCard(title: "Night only", points: nightPoints, tint: StrandPalette.metricPurple)
            }
            Text("The whole-day figure is the mean heart rate across the entire day, including sleep. The night-only figure is the mean over your longest sleep session — the same shadow metric validated for issue #1169. Both are approximate.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task { await load() }
    }

    private var headlineCard: some View {
        NoopCard {
            HStack(spacing: 24) {
                statColumn(label: "Whole day", value: todayDayMean, tint: StrandPalette.metricRose)
                statColumn(label: "Night only", value: todayNightMean, tint: StrandPalette.metricPurple)
            }
        }
    }

    private func statColumn(label: LocalizedStringKey, value: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(value.map { "\(Int($0.rounded())) bpm" } ?? "—")
                .font(StrandFont.rounded(24, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trendCard(title: LocalizedStringKey, points: [TrendPoint], tint: Color) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                Text(title).strandOverline()
                if points.count >= 2 {
                    TrendChart(points: points,
                              gradient: Gradient(stops: [.init(color: tint.opacity(0.55), location: 0), .init(color: tint, location: 1)]),
                              valueRange: 30...120, showsArea: true, height: NoopMetrics.chartHeight,
                              valueFormat: { "\(Int($0.rounded())) bpm" },
                              accessibilityLabel: String(localized: "\(title) heart rate trend"))
                } else {
                    Text("Not enough data for this window.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(height: NoopMetrics.chartHeight, alignment: .center)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Local `yyyy-MM-dd` parser, duplicated rather than cross-imported (same precedent as
    /// `NutritionView`'s own copy).
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func load() async {
        async let dayA = repo.exploreSeries(key: "day_mean_hr", source: "my-whoop", days: Self.historyDays)
        async let nightA = repo.exploreSeries(key: "rhr_primary_session", source: "my-whoop", days: Self.historyDays)
        let day = await dayA
        let night = await nightA

        func toPoints(_ series: [(day: String, value: Double)]) -> [TrendPoint] {
            series.compactMap { row in
                Self.dayKeyParser.date(from: row.day).map { TrendPoint(date: $0, value: row.value) }
            }
        }
        dayPoints = toPoints(day)
        nightPoints = toPoints(night)
        loaded = true
    }
}
