#if os(iOS)
import SwiftUI
import MarkdownUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// FORK-ONLY, not ported to Android. The week in review: the existing deterministic digest (Charge,
/// Effort, Rest, HRV, resting HR, week over week) plus sleep, training, breathing and nutrition for the
/// same Monday-to-Sunday week, and an optional AI summary through the same Coach as the rest of the app.
/// Reached from More › Insights and from the Sunday 20:00 reminder (`WeeklyRecapNotifier`).
struct WeeklyRecapView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @StateObject private var profile = ProfileStore()

    /// 0 = this week, 1 = last week.
    @State private var weeksBack = 0
    @State private var training: WeeklyRecapStats.Training?
    @State private var previousTrainingMinutes = 0.0
    @State private var breathingSessions = 0
    @State private var breathingMinutes = 0
    @State private var loggedDays = 0
    @State private var proteinHitDays = 0
    @State private var aiText: String?
    @State private var aiLoading = false
    @State private var aiFailed = false
    @State private var notifyOn = WeeklyRecapNotifier.isEnabled

    private var anchorDay: String {
        WeeklyDigestEngine.addDays(Repository.localDayKey(Date()), -7 * weeksBack)
    }
    private var week: [String] { WeeklyRecapStats.weekDays(containing: anchorDay) }
    private var weekDays: [DailyMetric] { repo.days.filter { Set(week).contains($0.day) } }

    var body: some View {
        ScreenScaffold(title: "Bilan de la semaine",
                       subtitle: "\(rangeLabel)",
                       topBackground: liquidScaffoldSky()) {
            Picker("Semaine", selection: $weeksBack) {
                Text("Cette semaine").tag(0)
                Text("Semaine dernière").tag(1)
            }
            .pickerStyle(.segmented)

            let digest = WeeklyDigestSource.digest(from: repo.days, anchorDay: anchorDay)
            if !digest.isEmpty {
                WeeklyDigestContent(digest: digest, compact: false, showsHeader: false)
            }
            sleepCard
            trainingCard
            breathingCard
            nutritionCard
            aiCard
            NoopCard {
                Toggle(isOn: $notifyOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Me prévenir le dimanche à 20 h").font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Une notification quand le bilan de la semaine est prêt.").font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .onChange(of: notifyOn) { _, on in WeeklyRecapNotifier.setEnabled(on) }
            }
        }
        .task(id: weeksBack) { await load() }
    }

    // MARK: - Cards

    private var sleepCard: some View {
        let s = WeeklyRecapStats.sleep(
            minutesByDay: Dictionary(weekDays.compactMap { d in d.totalSleepMin.map { (d.day, $0) } }, uniquingKeysWith: { a, _ in a }),
            efficiencyByDay: Dictionary(weekDays.compactMap { d in d.efficiency.map { (d.day, $0) } }, uniquingKeysWith: { a, _ in a }),
            week: Set(week))
        return section("Sommeil", icon: "bed.double.fill", tint: StrandPalette.restColor) {
            if let s {
                row("Sommeil moyen", hm(s.avgMinutes))
                row("Nuits enregistrées", "\(s.nights)")
                if let e = s.avgEfficiency { row("Efficacité moyenne", "\(Int((e <= 1 ? e * 100 : e).rounded())) %") }
            } else {
                empty("Pas de nuit enregistrée cette semaine.")
            }
        }
    }

    private var trainingCard: some View {
        section("Entraînement", icon: "figure.run", tint: StrandPalette.effortColor) {
            if let t = training, t.count > 0 {
                row("Séances", "\(t.count)")
                row("Temps total", hm(t.minutes))
                if t.distanceKm > 0 { row("Distance", String(format: "%.1f km", t.distanceKm)) }
                let delta = t.minutes - previousTrainingMinutes
                if previousTrainingMinutes > 0 {
                    row("Par rapport à la semaine d'avant", (delta >= 0 ? "+" : "−") + hm(abs(delta)))
                }
                ForEach(t.bySport, id: \.name) { s in
                    row("• \(WorkoutSource.displaySport(s.name))", "\(s.count) × · \(hm(s.minutes))")
                }
            } else {
                empty("Pas de séance enregistrée cette semaine.")
            }
        }
    }

    private var breathingCard: some View {
        section("Respiration", icon: "wind", tint: StrandPalette.metricCyan) {
            if breathingSessions > 0 {
                row("Séances", "\(breathingSessions)")
                row("Temps guidé", "\(breathingMinutes) min")
            } else {
                empty("Pas de séance de respiration cette semaine.")
            }
        }
    }

    private var nutritionCard: some View {
        section("Nutrition", icon: "fork.knife", tint: StrandPalette.metricAmber) {
            if loggedDays > 0 {
                row("Jours notés", "\(loggedDays) / 7")
                row("Objectif de protéines atteint", "\(proteinHitDays) / \(loggedDays) jours")
            } else {
                empty("Aucun repas noté cette semaine.")
            }
        }
    }

    private var aiCard: some View {
        section("Résumé du coach", icon: "sparkles", tint: StrandPalette.accent) {
            if let aiText {
                Markdown(aiText).markdownTheme(.strand)
            } else if aiLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("L'IA résume ta semaine…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            } else {
                if aiFailed {
                    Text("L'IA n'a pas répondu. Vérifie la clé et l'accès aux données dans les réglages du Coach.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                NoopButton("Résumer ma semaine avec l'IA", systemImage: "sparkles", fullWidth: true) {
                    Task { await runAI() }
                }
            }
        }
    }

    // MARK: - Pieces

    private func section<C: View>(_ title: LocalizedStringKey, icon: String, tint: Color,
                                  @ViewBuilder _ content: () -> C) -> some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                content()
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 12)
            Text(verbatim: value).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func empty(_ text: String) -> some View {
        Text(verbatim: text).font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
    }

    private func hm(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(m) min"
    }

    private var rangeLabel: String {
        guard let first = week.first, let last = week.last else { return "" }
        func short(_ d: String) -> String {
            guard let (_, m, day) = WeeklyDigestEngine.parseYMD(d) else { return d }
            return String(format: "%02d/%02d", day, m)
        }
        return "Du \(short(first)) au \(short(last))"
    }

    private static func dayKey(_ ts: Int) -> String {
        Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // MARK: - Load

    @MainActor
    private func load() async {
        aiText = WeekAICache.load(week.first ?? "")
        aiFailed = false
        let thisWeek = Set(week)
        let previous = Set(WeeklyRecapStats.weekDays(containing: WeeklyDigestEngine.addDays(anchorDay, -7)))
        let rows = await repo.workoutRows(days: 7 * (weeksBack + 2) + 2)
        training = WeeklyRecapStats.training(rows, week: thisWeek, dayOf: Self.dayKey)
        previousTrainingMinutes = WeeklyRecapStats.training(rows, week: previous, dayOf: Self.dayKey).minutes

        let breaths = BreathingHistoryStore.load().filter { thisWeek.contains(Self.dayKey($0.ts)) }
        breathingSessions = breaths.count
        breathingMinutes = breaths.reduce(0) { $0 + $1.guidedSeconds } / 60

        let protein = await repo.series(key: "protein_g", source: NutritionStore.metricSeriesSourceId,
                                        days: 7 * (weeksBack + 1) + 2)
        let calories = await repo.series(key: "calories_in", source: NutritionStore.metricSeriesSourceId,
                                         days: 7 * (weeksBack + 1) + 2)
        let logged = Set(calories.filter { thisWeek.contains($0.day) && $0.value > 0 }.map { $0.day })
        loggedDays = logged.count
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        proteinHitDays = protein.filter { p in
            guard logged.contains(p.day) else { return false }
            let d = byDay[p.day]
            let target = MacroTargets.dailyTargets(weightKg: profile.weightKg, effort: d?.strain,
                                                   dailyEnergyKcal: d?.activeKcalEst)
            return p.value >= Double(target.proteinG) * 0.9
        }.count
    }

    @MainActor
    private func runAI() async {
        aiLoading = true
        aiFailed = false
        defer { aiLoading = false }
        guard let reply = await coach.headlessAnswer(prompt()) else { aiFailed = true; return }
        aiText = reply
        WeekAICache.save(reply, week: week.first ?? "")
    }

    private func prompt() -> String {
        func mean(_ xs: [Double]) -> String? { xs.isEmpty ? nil : String(Int((xs.reduce(0, +) / Double(xs.count)).rounded())) }
        var l = ["Voici ma semaine (\(rangeLabel)). Fais-m'en un bilan."]
        if let v = mean(weekDays.compactMap(\.recovery)) { l.append("- Charge moyenne : \(v)/100") }
        if let v = mean(weekDays.compactMap(\.strain)) { l.append("- Effort moyen par jour : \(v)/100") }
        if let v = mean(weekDays.compactMap(\.avgHrv)) { l.append("- VFC moyenne : \(v) ms") }
        if let v = mean(weekDays.compactMap { $0.restingHr.map(Double.init) }) { l.append("- FC de repos moyenne : \(v) bpm") }
        if let v = mean(weekDays.compactMap(\.totalSleepMin)) { l.append("- Sommeil moyen : \(hm(Double(v) ?? 0))") }
        if let t = training {
            l.append("- Entraînement : \(t.count) séance(s), \(hm(t.minutes)) (semaine d'avant : \(hm(previousTrainingMinutes)))")
            for s in t.bySport { l.append("  • \(WorkoutSource.displaySport(s.name)) : \(s.count) × \(hm(s.minutes))") }
        }
        l.append("- Respiration : \(breathingSessions) séance(s), \(breathingMinutes) min")
        l.append("- Nutrition : \(loggedDays) jour(s) notés, protéines atteintes \(proteinHitDays) jour(s)")
        l.append("")
        l.append("""
        En français, court et concret, avec des titres ### : « Ta semaine en bref » (2-3 phrases), \
        « Ce qui va bien », « À améliorer », et « La semaine prochaine » (un plan simple jour par jour \
        en tenant compte de ma récupération). Pas de diagnostic médical.
        """)
        return l.joined(separator: "\n")
    }
}

/// The last weekly AI summaries, by the week's Monday, so reopening the recap does not ask again.
private enum WeekAICache {
    private static let key = "weeklyRecap.ai.v1"
    static func load(_ monday: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[monday]
    }
    static func save(_ text: String, week monday: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[monday] = text
        if all.count > 12, let oldest = all.keys.sorted().first { all.removeValue(forKey: oldest) }
        UserDefaults.standard.set(all, forKey: key)
    }
}
#endif
