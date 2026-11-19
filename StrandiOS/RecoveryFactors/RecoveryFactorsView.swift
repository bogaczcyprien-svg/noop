#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// FORK-ONLY, not ported to Android. "Ce qui joue sur ta récupération": habits NOOP sees by itself —
/// no Journal logging needed (the Journal-based ranking already lives in "What Moves You") — compared
/// against the next morning's Charge with `RecoveryFactors`. Association on the user's own days only,
/// never a cause.
struct RecoveryFactorsView: View {
    @EnvironmentObject private var repo: Repository
    @State private var factors: [RecoveryFactors.Factor] = []
    @State private var dayCount = 0
    @State private var loaded = false

    static let windowDays = 90

    static let labels: [String: (title: String, icon: String)] = [
        "lateWorkout": ("Sport après 20 h", "figure.run"),
        "hardDay": ("Grosse journée d'effort", "flame"),
        "eveningBreathing": ("Respiration le soir", "wind"),
        "lateMeal": ("Repas après 21 h", "fork.knife"),
        "lateBed": ("Coucher après minuit", "moon.zzz"),
    ]

    var body: some View {
        ScreenScaffold(title: "Ce qui joue sur ta récupération",
                       subtitle: "Tes habitudes comparées à ta Charge du lendemain matin.") {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                if !loaded {
                    StrandCard(padding: 18) { Text("Analyse en cours…").font(StrandFont.subhead) }
                } else if factors.isEmpty {
                    StrandCard(padding: 18) {
                        Text("Pas encore assez de jours pour conclure. Il faut au moins 3 jours avec et 3 jours sans une habitude, et une différence d'au moins 3 points de Charge. Reviens dans quelques jours.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    ForEach(factors, id: \.id) { factorCard($0) }
                }
                Text("Basé sur tes \(dayCount) derniers jours. Ce sont des tendances sur tes propres données, pas des causes certaines : une habitude peut aller avec une autre (par exemple, sport tard et coucher tard).")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await load() }
    }

    private func factorCard(_ f: RecoveryFactors.Factor) -> some View {
        let label = Self.labels[f.id] ?? (f.id, "circle")
        let good = f.delta > 0
        let color = good ? StrandPalette.chargeColor : StrandPalette.metricRose
        let points = Int(abs(f.delta).rounded())
        return StrandCard(padding: 16) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().fill(color.opacity(0.15)).frame(width: 44, height: 44)
                    Image(systemName: label.icon).foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Charge \(Int(f.yesMean.rounded())) % le lendemain, contre \(Int(f.noMean.rounded())) % sans (\(f.yesCount) jours avec, \(f.noCount) sans).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("\(good ? "+" : "−")\(points)")
                    .font(StrandFont.title2.monospacedDigit())
                    .foregroundStyle(color)
            }
        }
    }

    // MARK: - Load

    @MainActor
    private func load() async {
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days: [String] = (1...Self.windowDays).reversed().compactMap { back in
            cal.date(byAdding: .day, value: -back, to: today).map { Repository.localDayKey($0) }
        }
        func nextDay(_ d: String) -> String? {
            guard let date = PushDayFormat.formatter.date(from: d),
                  let n = cal.date(byAdding: .day, value: 1, to: date) else { return nil }
            return Repository.localDayKey(n)
        }
        func hour(_ ts: Int) -> Double {
            let c = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(ts)))
            return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
        }
        func dayKey(_ ts: Int) -> String { Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(ts))) }

        // Workouts: latest end hour per day.
        let workouts = await repo.workoutRows(days: Self.windowDays + 2)
        var lastWorkoutEnd: [String: Double] = [:]
        for w in workouts {
            let k = dayKey(w.startTs)
            lastWorkoutEnd[k] = max(lastWorkoutEnd[k] ?? 0, hour(w.endTs) < hour(w.startTs) ? 24 : hour(w.endTs))
        }

        // Effort: personal thresholds (top 30 % vs bottom 40 %).
        let strains = days.compactMap { byDay[$0]?.strain }.sorted()
        let hi = strains.isEmpty ? nil : strains[Int(Double(strains.count - 1) * 0.7)]
        let lo = strains.isEmpty ? nil : strains[Int(Double(strains.count - 1) * 0.4)]

        // Breathing: only days since the first recorded session count.
        let breaths = BreathingHistoryStore.load()
        let firstBreathDay = breaths.map(\.ts).min().map(dayKey)
        var eveningBreath = Set<String>()
        for b in breaths where hour(b.ts) >= 19 { eveningBreath.insert(dayKey(b.ts)) }

        // Meals: only days with logged food.
        let calories = await repo.series(key: "calories_in", source: NutritionStore.metricSeriesSourceId,
                                         days: Self.windowDays + 2)
        let loggedDays = Set(calories.filter { $0.value > 0 }.map(\.day))
        var lastMealHour: [String: Double] = [:]
        for d in days where loggedDays.contains(d) {
            let meals = await repo.meals(day: d)
            if let last = meals.map(\.loggedAt).max() { lastMealHour[d] = hour(last) }
        }

        // Bedtime: the onset of the night that ENDS on the next morning.
        let now = Int(Date().timeIntervalSince1970)
        var sessions = await repo.sleepSessions(from: now - (Self.windowDays + 2) * 86_400, to: now, limit: 400)
        if sessions.isEmpty {
            sessions = await repo.computedSleepSessions(from: now - (Self.windowDays + 2) * 86_400, to: now,
                                                        limit: 400)
        }
        var onsetByEveningDay: [String: Double] = [:]
        for s in sessions where s.endTs - s.startTs >= 3 * 3_600 {
            let h = hour(s.startTs)
            // An onset after midnight belongs to the previous evening.
            let evening = h < 12 ? dayKey(s.startTs - 12 * 3_600) : dayKey(s.startTs)
            onsetByEveningDay[evening] = h < 12 ? h + 24 : h
        }

        var input: [RecoveryFactors.Day] = []
        for d in days {
            guard let n = nextDay(d), let charge = byDay[n]?.recovery else { continue }
            var flags: [String: Bool] = [:]
            flags["lateWorkout"] = (lastWorkoutEnd[d] ?? 0) >= 20
            if let s = byDay[d]?.strain, let hi, let lo {
                if s >= hi { flags["hardDay"] = true } else if s <= lo { flags["hardDay"] = false }
            }
            if let first = firstBreathDay, d >= first { flags["eveningBreathing"] = eveningBreath.contains(d) }
            if let m = lastMealHour[d] { flags["lateMeal"] = m >= 21 }
            if let onset = onsetByEveningDay[d] {
                if onset >= 24 { flags["lateBed"] = true } else if onset <= 23.5 { flags["lateBed"] = false }
            }
            input.append(.init(day: d, nextCharge: charge, flags: flags))
        }
        dayCount = input.count
        factors = RecoveryFactors.analyse(input)
        loaded = true
    }
}
#endif
