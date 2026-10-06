#if os(iOS)
import SwiftUI
import StrandDesign

/// Upcoming planned workouts from intervals.icu's calendar (the Events API, `category=WORKOUT`) — an
/// AGENDA of what's coming, not what already happened (see `IntervalsICUActivitiesView` for that).
/// Read-only against intervals.icu's public API; nothing is written back. Fork addition.
///
/// Grouped by day rather than drawn as a month grid: a training plan is read top-to-bottom ("what's
/// next"), and a day-by-day agenda shows exactly that without empty grid cells for rest days.
struct IntervalsICUPlannedSection: View {
    @State private var events: [IntervalsICUEvent] = []
    @State private var loaded = false
    @State private var loadFailed = false

    /// Cap the number of UPCOMING DAYS shown — the Today embedding passes a small number so it
    /// doesn't dump the whole plan onto the home screen; nil (the "See all" destination) shows
    /// everything fetched. Capped by DAY, not by event count, so a day with 2 sessions never gets
    /// split across the cap boundary.
    var dayLimit: Int? = nil

    private var sortedEvents: [IntervalsICUEvent] {
        events.sorted { ($0.start_date_local ?? "") < ($1.start_date_local ?? "") }
    }

    private var groupedByDay: [(day: String, events: [IntervalsICUEvent])] {
        var order: [String] = []
        var byDay: [String: [IntervalsICUEvent]] = [:]
        for event in sortedEvents {
            let day = String(event.start_date_local?.prefix(10) ?? "")
            guard !day.isEmpty else { continue }
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(event)
        }
        let groups = order.map { (day: $0, events: byDay[$0] ?? []) }
        guard let dayLimit else { return groups }
        return Array(groups.prefix(dayLimit))
    }

    /// Total distinct upcoming days with at least one planned session — independent of `dayLimit`,
    /// so the "See the full calendar" link can tell whether capping actually hid anything.
    private var totalDayCount: Int {
        Set(sortedEvents.compactMap { event -> String? in
            let day = String(event.start_date_local?.prefix(10) ?? "")
            return day.isEmpty ? nil : day
        }).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Planned Training", overline: "intervals.icu")

            if events.isEmpty {
                StrandCard(padding: 20) {
                    Text(emptyStateText)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(groupedByDay, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        dayHeader(group.day)
                        ForEach(group.events, id: \.id) { event in
                            eventCard(event)
                        }
                    }
                }
                if dayLimit != nil, groupedByDay.count < totalDayCount {
                    NavigationLink {
                        IntervalsICUPlannedScreen()
                    } label: {
                        StrandCard(padding: 16) {
                            HStack {
                                Text("See the full calendar")
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

    private var emptyStateText: String {
        if !loaded { return "Loading…" }
        if loadFailed { return "Couldn't reach intervals.icu. Check your connection or API key in Settings." }
        return "No planned workouts on your intervals.icu calendar right now."
    }

    // MARK: - Day header

    private func dayHeader(_ dayKey: String) -> some View {
        HStack(spacing: 8) {
            Text(relativeDayLabel(dayKey))
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            Rectangle()
                .fill(StrandPalette.hairline)
                .frame(height: 1)
        }
        .padding(.top, 4)
    }

    /// "Today" / "Tomorrow" / a weekday+date — the small, concrete touch that makes an agenda
    /// readable at a glance instead of making every reader do the date math themselves.
    private func relativeDayLabel(_ dayKey: String) -> String {
        guard let date = Self.dayFormatter.date(from: dayKey) else { return dayKey }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return String(localized: "Today") }
        if cal.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        let daysAway = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: date).day ?? 0
        let weekday = date.formatted(.dateTime.weekday(.wide))
        let shortDate = date.formatted(.dateTime.day().month(.abbreviated))
        return daysAway < 7
            ? "\(weekday) · \(shortDate)"
            : String(localized: "\(weekday) · \(shortDate) · in \(daysAway) days")
    }

    // MARK: - Event card

    private func eventCard(_ event: IntervalsICUEvent) -> some View {
        StrandCard(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.name ?? event.type ?? "Workout")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let time = timeLabel(event.start_date_local) {
                            Text(time)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    Spacer()
                    Image(systemName: sportIcon(event.type))
                        .foregroundStyle(sportColor(event.type))
                }

                if let description = event.description, !description.isEmpty {
                    Text(description)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if event.moving_time != nil || event.distance != nil {
                    HStack(spacing: 16) {
                        if let seconds = event.moving_time, seconds > 0 {
                            statPair("Planned", formatDuration(seconds))
                        }
                        if let meters = event.distance, meters > 0 {
                            statPair("Distance", String(format: "%.1f km", meters / 1_000))
                        }
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

    // MARK: - Formatting

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    private func timeLabel(_ startDateLocal: String?) -> String? {
        guard let startDateLocal, let date = Self.dateTimeFormatter.date(from: startDateLocal) else { return nil }
        // Midnight is intervals.icu's own "no specific time set" convention for a planned workout —
        // showing "12:00 AM" would claim a precision the plan never had.
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        if comps.hour == 0 && comps.minute == 0 { return nil }
        return date.formatted(.dateTime.hour().minute())
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3_600, m = (seconds % 3_600) / 60
        return h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m) min"
    }

    private func sportIcon(_ sport: String?) -> String {
        switch (sport ?? "").lowercased() {
        case let s where s.contains("ride") || s.contains("bike") || s.contains("cycl"):
            return "figure.outdoor.cycle"
        case let s where s.contains("run"):
            return "figure.run"
        case let s where s.contains("swim"):
            return "figure.pool.swim"
        case let s where s.contains("strength") || s.contains("weight"):
            return "dumbbell.fill"
        case let s where s.contains("yoga"):
            return "figure.yoga"
        case let s where s.contains("row"):
            return "figure.rower"
        default:
            return "figure.mixed.cardio"
        }
    }

    /// A small touch beyond the activities list's single accent icon: each sport keeps its own tint,
    /// so a week with mixed disciplines reads at a glance instead of every icon being identical.
    private func sportColor(_ sport: String?) -> Color {
        switch (sport ?? "").lowercased() {
        case let s where s.contains("ride") || s.contains("bike") || s.contains("cycl"):
            return StrandPalette.accent
        case let s where s.contains("run"):
            return StrandPalette.metricRose
        case let s where s.contains("swim"):
            return StrandPalette.metricCyan
        case let s where s.contains("strength") || s.contains("weight"):
            return StrandPalette.metricPurple
        default:
            return StrandPalette.textSecondary
        }
    }

    // MARK: - Load

    private func load() async {
        guard let apiKey = await IntervalsICUSettings.shared.apiKey(), !apiKey.isEmpty else {
            loaded = true
            return
        }
        let athleteId = await IntervalsICUSettings.shared.athleteId
        let client = IntervalsICUClient(athleteId: athleteId, apiKey: apiKey)
        let cal = Calendar.current
        let today = Date()
        // Three weeks out: enough to show a real training block without asking the API for a year
        // of calendar it then has to filter client-side.
        let to = cal.date(byAdding: .day, value: 21, to: today) ?? today
        do {
            events = try await client.events(
                oldest: PushDayFormat.formatter.string(from: today),
                newest: PushDayFormat.formatter.string(from: to),
                category: "WORKOUT"
            )
            loadFailed = false
        } catch {
            events = []
            loadFailed = true
        }
        loaded = true
    }
}

/// The full, uncapped planned-training agenda — reached via the Today section's "See the full
/// calendar" link, or directly from More. Fork addition.
struct IntervalsICUPlannedScreen: View {
    var body: some View {
        ScreenScaffold(
            title: "Planned Training",
            subtitle: "Your upcoming sessions from intervals.icu."
        ) {
            IntervalsICUPlannedSection()
        }
    }
}

/// Today's own compact preview: the SINGLE next upcoming planned workout — name, when, what it
/// involves — tapping through to the full agenda (`IntervalsICUPlannedScreen`). Separate from
/// `IntervalsICUPlannedSection` on purpose: Today gets one headline card, not a list, the same
/// "preview + See all" shape `IntervalsICUActivitiesSection` already uses for recent activities.
/// Fork addition.
struct IntervalsICUNextPlannedCard: View {
    @State private var next: IntervalsICUEvent?
    @State private var loaded = false

    var body: some View {
        Group {
            if let next {
                NavigationLink {
                    IntervalsICUPlannedScreen()
                } label: {
                    cardBody(next)
                }
                .buttonStyle(.plain)
            } else if loaded {
                EmptyView()   // nothing planned — no card rather than an empty one
            }
        }
        .task { await load() }
    }

    private func cardBody(_ event: IntervalsICUEvent) -> some View {
        StrandCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Next Session").strandOverline()
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(sportColor(event.type).opacity(0.16))
                            .frame(width: 44, height: 44)
                        Image(systemName: sportIcon(event.type))
                            .foregroundStyle(sportColor(event.type))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(event.name ?? event.type ?? "Workout")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(2)
                        Text(whenLabel(event))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                        if let description = event.description, !description.isEmpty {
                            Text(description)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// "Today · 6:00 PM", "Tomorrow", "In 3 days" — the quick-read countdown the user asked for,
    /// combined with the planned duration when the plan carries one.
    private func whenLabel(_ event: IntervalsICUEvent) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = .current
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let date = event.start_date_local.flatMap({ df.date(from: $0) }) else {
            return String(localized: "Upcoming")
        }
        let cal = Calendar.current
        var when: String
        if cal.isDateInToday(date) { when = String(localized: "Today") }
        else if cal.isDateInTomorrow(date) { when = String(localized: "Tomorrow") }
        else {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: date).day ?? 0
            when = days > 0 ? String(localized: "In \(days) days") : date.formatted(.dateTime.weekday(.wide))
        }
        let comps = cal.dateComponents([.hour, .minute], from: date)
        if !(comps.hour == 0 && comps.minute == 0) {
            when += " · " + date.formatted(.dateTime.hour().minute())
        }
        if let seconds = event.moving_time, seconds > 0 {
            let h = seconds / 3_600, m = (seconds % 3_600) / 60
            when += " · " + (h > 0 ? "\(h)h\(String(format: "%02d", m))" : "\(m) min")
        }
        return when
    }

    private func sportIcon(_ sport: String?) -> String {
        switch (sport ?? "").lowercased() {
        case let s where s.contains("ride") || s.contains("bike") || s.contains("cycl"):
            return "figure.outdoor.cycle"
        case let s where s.contains("run"):
            return "figure.run"
        case let s where s.contains("swim"):
            return "figure.pool.swim"
        case let s where s.contains("strength") || s.contains("weight"):
            return "dumbbell.fill"
        default:
            return "figure.mixed.cardio"
        }
    }

    private func sportColor(_ sport: String?) -> Color {
        switch (sport ?? "").lowercased() {
        case let s where s.contains("ride") || s.contains("bike") || s.contains("cycl"):
            return StrandPalette.accent
        case let s where s.contains("run"):
            return StrandPalette.metricRose
        case let s where s.contains("swim"):
            return StrandPalette.metricCyan
        default:
            return StrandPalette.textSecondary
        }
    }

    private func load() async {
        defer { loaded = true }
        guard let apiKey = await IntervalsICUSettings.shared.apiKey(), !apiKey.isEmpty else { return }
        let athleteId = await IntervalsICUSettings.shared.athleteId
        let client = IntervalsICUClient(athleteId: athleteId, apiKey: apiKey)
        let cal = Calendar.current
        let today = Date()
        let to = cal.date(byAdding: .day, value: 21, to: today) ?? today
        guard let events = try? await client.events(
            oldest: PushDayFormat.formatter.string(from: today),
            newest: PushDayFormat.formatter.string(from: to),
            category: "WORKOUT"
        ) else { return }
        next = events.sorted { ($0.start_date_local ?? "") < ($1.start_date_local ?? "") }.first
    }
}
#endif
