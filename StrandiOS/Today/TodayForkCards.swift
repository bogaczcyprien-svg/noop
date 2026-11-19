#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// FORK-ONLY, not ported to Android. The cards shown right under Today's Charge/Effort/Rest hero:
/// the "history stalled" banner (only when it applies) and tonight's bedtime → wake card.
struct TodayForkCards: View {
    var body: some View {
        VStack(spacing: NoopMetrics.gap) {
            HistoryStallBanner()
            TonightSleepCard()
        }
    }
}

/// Shown only while `HistoryStallMonitor` reports a stall: live data still flows but the strap has not
/// handed over any history for a day and a half.
struct HistoryStallBanner: View {
    @State private var status: HistoryStallMonitor.Status = .ok

    var body: some View {
        Group {
            if case .stalled(let hours) = status {
                NoopCard(tint: StrandPalette.statusWarning) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(StrandPalette.statusWarning)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("L'historique ne passe plus")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text("Ta WHOOP est connectée, mais elle ne donne plus son historique depuis \(hours) h. Le direct marche encore. Exporte le journal du bracelet (Appareils) pour qu'on regarde.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .task { status = HistoryStallStamps.status() }
    }
}

/// Tonight: when to go to bed and when you wake, drawn as a night arc from a moon to a sun.
/// Bedtime = wake time − (sleep need + part of the sleep debt), via `BedtimeRecommendation`.
struct TonightSleepCard: View {
    @EnvironmentObject var repo: Repository

    private struct Plan: Equatable {
        let bedtime: Int        // minutes since midnight
        let wake: Int
        let targetMin: Double
        let debtMin: Double
        let wakeSource: String
    }

    @State private var plan: Plan?
    @State private var now = Date()

    var body: some View {
        Group {
            if let plan {
                NoopCard(tint: StrandPalette.restColor) {
                    VStack(spacing: 14) {
                        HStack {
                            Text("Ce soir").strandOverline()
                            Spacer()
                            Text(countdown(plan))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.restBright)
                        }
                        arc(plan)
                        if plan.debtMin > 0 {
                            Text("Dont \(Int(plan.debtMin.rounded())) min pour rattraper ta dette de sommeil.")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Text(plan.wakeSource)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
        .task(id: repo.days.count) { await load() }
    }

    private func arc(_ plan: Plan) -> some View {
        let width: CGFloat = 260
        let height: CGFloat = 140
        return ZStack(alignment: .bottom) {
            NightArc()
                .stroke(StrandPalette.restColor.opacity(0.18),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
            NightArc()
                .stroke(LinearGradient(colors: [StrandPalette.restDeep, StrandPalette.restBright,
                                                StrandPalette.effortBright],
                                       startPoint: .leading, endPoint: .trailing),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round))
            // Stars along the night sky.
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "sparkle")
                    .font(.system(size: [9, 7, 8][i]))
                    .foregroundStyle(StrandPalette.restBright.opacity(0.6))
                    .offset(x: [-55, 10, 60][i], y: [-78, -96, -70][i])
            }
            VStack(spacing: 2) {
                Text(duration(plan.targetMin))
                    .font(StrandFont.title1.monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("de sommeil visé")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.bottom, 8)
        }
        .frame(width: width, height: height)
        .overlay(alignment: .bottomLeading) {
            endpoint(icon: "moon.stars.fill", color: StrandPalette.restBright,
                     label: "Coucher", time: plan.bedtime)
                .offset(x: -18, y: 46)
        }
        .overlay(alignment: .bottomTrailing) {
            endpoint(icon: "sun.max.fill", color: StrandPalette.effortBright,
                     label: "Réveil", time: plan.wake)
                .offset(x: 18, y: 46)
        }
        .padding(.bottom, 46)
        .frame(maxWidth: .infinity)
    }

    private func endpoint(icon: String, color: Color, label: String, time: Int) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(color)
            Text(BedtimeRecommendation.formatClock(time))
                .font(StrandFont.headline.monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(width: 76)
    }

    private func duration(_ min: Double) -> String {
        let m = Int(min.rounded())
        return "\(m / 60)h\(String(format: "%02d", m % 60))"
    }

    /// "Coucher dans 2 h 10", or a nudge once bedtime has passed and wake time hasn't come yet.
    private func countdown(_ plan: Plan) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMin = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let toBed = ((plan.bedtime - nowMin) % 1_440 + 1_440) % 1_440
        let toWake = ((plan.wake - nowMin) % 1_440 + 1_440) % 1_440
        if toWake < toBed { return "C'est l'heure de dormir" }
        if toBed == 0 { return "C'est l'heure de dormir" }
        let h = toBed / 60, m = toBed % 60
        return h > 0 ? "Coucher dans \(h) h \(String(format: "%02d", m))" : "Coucher dans \(m) min"
    }

    private func load() async {
        now = Date()
        let series = repo.days.map { (day: $0.day, totalSleepMin: $0.totalSleepMin) }
        let ledger = SleepDebt.ledger(series: series)

        let defaults = UserDefaults.standard
        var wake: Int?
        var source = ""
        if defaults.bool(forKey: "behavior.smartAlarmEnabled") {
            wake = defaults.object(forKey: "behavior.smartAlarmMinutes") as? Int ?? 7 * 60
            source = "Réveil : ton alarme intelligente."
        } else if WindDownNudge.isEnabled {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
            wake = WindDownNudge.wakeMinutes(forWeekday: Calendar.current.component(.weekday, from: tomorrow))
            source = "Réveil : ton heure de réveil réglée dans le rappel du coucher."
        } else {
            let to = Int(now.timeIntervalSince1970)
            var sessions = await repo.sleepSessions(from: to - 7 * 86_400, to: to, limit: 20)
            if sessions.isEmpty {
                sessions = await repo.computedSleepSessions(from: to - 7 * 86_400, to: to, limit: 20)
            }
            if !sessions.isEmpty {
                let tz = TimeZone.current.secondsFromGMT()
                let mins = sessions.map { (($0.endTs + tz) % 86_400 + 86_400) % 86_400 / 60 }
                wake = mins.reduce(0, +) / mins.count
                source = "Réveil : ta moyenne des 7 dernières nuits."
            }
        }
        guard let wake else { plan = nil; return }
        let rec = BedtimeRecommendation.recommend(
            debtBalanceMin: ledger.nightCount > 0 ? ledger.balanceMin : 0,
            baseNeedMin: AnalyticsEngine.Rest.defaultNeedHours * 60,
            habitualWakeMinutes: wake)
        plan = Plan(bedtime: rec.bedtimeMinutes, wake: wake, targetMin: rec.targetSleepMin,
                    debtMin: rec.debtOwedMin, wakeSource: source)
    }
}

/// The upper half of a circle, drawn from 9 o'clock over the top to 3 o'clock.
private struct NightArc: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width / 2, rect.height) - 8
        let center = CGPoint(x: rect.midX, y: rect.maxY)
        var p = Path()
        p.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(360),
                 clockwise: false)
        return p
    }
}
#endif
