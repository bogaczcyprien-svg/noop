import SwiftUI
import MarkdownUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import WhoopProtocol
import Foundation

// MARK: - Per-session debrief page (FORK-ONLY, not ported to Android)
//
// Opened from a session's detail screen (and from the intervals.icu activity cards). Shows what the
// session did, from its heart rate against the user's own zones (`WorkoutPhysiology`): the aerobic and
// anaerobic effect estimates, the main benefit, the aerobic/anaerobic split, time per zone and a few
// markers. Then an AI debrief through the same bring-your-own-key Coach the rest of the app uses
// (`AICoachEngine.headlessAnswer`), with no consent surface of its own. The debrief is kept on the
// device (`WorkoutDebriefCache`), so reopening the page does not ask the AI again.

struct WorkoutDebriefView: View {
    let row: WorkoutRow

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coach: AICoachEngine
    @StateObject private var profile = ProfileStore()

    private enum AIState: Equatable { case idle, loading, failed, notConfigured, noConsent }

    @State private var physiology: WorkoutPhysiology.Result?
    @State private var context: WorkoutDebrief.SessionContext?
    @State private var loaded = false
    @State private var aiText: String?
    @State private var aiState: AIState = .idle

    private var cardTint: Color { StrandPalette.effortColor }

    var body: some View {
        ScreenScaffold(title: "Débrief de la séance",
                       subtitle: "\(WorkoutSource.displaySport(row.sport)) · \(dateLabel)",
                       topBackground: liquidScaffoldSky()) {
            if !loaded {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Analyse de la séance…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            } else if let p = physiology {
                effectsCard(p)
                splitCard(p)
                zonesCard(p)
                markersCard(p)
            } else {
                NoopCard(tint: cardTint) {
                    Text("Pas de fréquence cardiaque enregistrée pendant cette séance : le débrief se base seulement sur sa durée et ses infos.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if loaded { aiCard }
        }
        .task { await load() }
    }

    // MARK: - Cards

    private func effectsCard(_ p: WorkoutPhysiology.Result) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Effets de la séance", overline: "Estimation NOOP")
            NoopCard(tint: cardTint) {
                VStack(alignment: .leading, spacing: 14) {
                    effectRow("Effet aérobie", value: p.aerobicEffect, tint: StrandPalette.metricCyan)
                    effectRow("Effet anaérobie", value: p.anaerobicEffect, tint: StrandPalette.metricRose)
                    Divider().overlay(StrandPalette.hairline)
                    HStack {
                        Text("Bénéfice principal").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        Spacer()
                        Text(verbatim: p.benefit.labelFR).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    }
                    Text("Calculé à partir de ta fréquence cardiaque et de tes zones. C'est une estimation de NOOP, pas le chiffre Garmin.")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func effectRow(_ label: LocalizedStringKey, value: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text(verbatim: String(format: "%.1f", value)).font(StrandFont.number(24)).foregroundStyle(tint)
                Text(verbatim: "/ 5").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            bar(fraction: value / 5, tint: tint)
            Text(verbatim: WorkoutPhysiology.effectLabelFR(value)).font(StrandFont.caption).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func splitCard(_ p: WorkoutPhysiology.Result) -> some View {
        let anaerobic = min(100, max(0, p.anaerobicSharePct))
        let aerobic = 100 - anaerobic
        return NoopCard(tint: cardTint) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aérobie / anaérobie").strandOverline()
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        Rectangle().fill(StrandPalette.metricCyan)
                            .frame(width: max(0, geo.size.width * aerobic / 100 - 1))
                        Rectangle().fill(StrandPalette.metricRose)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                HStack {
                    Text(verbatim: "Aérobie \(Int(aerobic.rounded())) %").font(StrandFont.caption).foregroundStyle(StrandPalette.metricCyan)
                    Spacer()
                    Text(verbatim: "Anaérobie \(Int(anaerobic.rounded())) %").font(StrandFont.caption).foregroundStyle(StrandPalette.metricRose)
                }
                Text("Part du temps au-dessus de ton seuil anaérobie estimé (le milieu de ta zone 4).")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func zonesCard(_ p: WorkoutPhysiology.Result) -> some View {
        let total = max(p.zoneMinutes.reduce(0, +), 0.1)
        let tints: [Color] = [StrandPalette.textTertiary, StrandPalette.metricCyan, StrandPalette.statusPositive,
                              StrandPalette.metricAmber, StrandPalette.effortColor, StrandPalette.metricRose]
        let bounds = p.zoneLowerBoundsBPM.map { Int($0.rounded()) }
        return NoopCard(tint: cardTint) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Temps par zone").strandOverline()
                ForEach([5, 4, 3, 2, 1, 0], id: \.self) { z in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: z == 0 ? "Sous la zone 1" : "Zone \(z)")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            if z > 0, bounds.count == 5 {
                                Text(verbatim: z == 5 ? "\(bounds[4])+ bpm" : "\(bounds[z - 1])–\(bounds[z] - 1) bpm")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                            Text(verbatim: "\(Int(p.zoneMinutes[z].rounded())) min")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        }
                        bar(fraction: p.zoneMinutes[z] / total, tint: tints[z])
                    }
                }
                Text(profile.hasCustomHRZones
                     ? "Tes zones personnelles. Tu peux les changer dans Réglages › Profil."
                     : "Zones par défaut (% de ta FC max). Tu peux régler les tiennes à la main dans Réglages › Profil.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func markersCard(_ p: WorkoutPhysiology.Result) -> some View {
        let c = context
        NoopCard(tint: cardTint) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Repères").strandOverline()
                marker("Efforts durs (30 s et plus)", "\(p.hardEfforts)")
                if let pk = p.peak60sHR { marker("Meilleure minute", "\(Int(pk.rounded())) bpm") }
                marker("FC moyenne · max", "\(Int(p.meanHR.rounded())) · \(p.peakHR) bpm")
                if let d = p.driftPct {
                    marker("Dérive cardiaque", (d >= 0 ? "+" : "") + String(format: "%.1f", d) + " %")
                }
                if let s = c?.substrate {
                    marker("Carburant", "\(Int(s.fatPct.rounded())) % graisses · \(Int(s.carbPct.rounded())) % glucides")
                }
                if let cr = c?.carbRefuel {
                    marker("Glucides à reprendre", "\(Int(cr.refuelTargetG.rounded())) g en \(Int(cr.windowHours.rounded())) h")
                }
                if let one = c?.heartRateRecovery?.after1Minute {
                    marker("Récupération cardiaque (1 min)", "−\(one) bpm")
                }
            }
        }
    }

    private func marker(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 12)
            Text(verbatim: value).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func bar(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline)
                Capsule().fill(tint).frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 6)
    }

    // MARK: - AI

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Débrief IA", overline: "Coach")
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: 12) {
                    if let text = aiText {
                        Markdown(text).markdownTheme(.strand)
                        Button {
                            Task { await runAI() }
                        } label: {
                            Label("Refaire le débrief", systemImage: "arrow.clockwise").font(StrandFont.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(StrandPalette.accent)
                        .disabled(aiState == .loading)
                    } else {
                        switch aiState {
                        case .loading:
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("L'IA prépare ton débrief…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            }
                        case .notConfigured, .noConsent:
                            Text(aiState == .notConfigured
                                 ? "Pour le débrief IA, ajoute ta clé IA dans les réglages du Coach."
                                 : "Pour le débrief IA, autorise le Coach à lire tes données dans ses réglages.")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            NavigationLink {
                                CoachSettingsView()
                            } label: {
                                Label("Réglages du Coach", systemImage: "gearshape").font(StrandFont.subhead)
                            }
                            .foregroundStyle(StrandPalette.accent)
                            NoopButton("J'ai réglé, lancer le débrief", systemImage: "sparkles", kind: .secondary, fullWidth: true) {
                                Task { await runAI() }
                            }
                        case .failed:
                            Text("L'IA n'a pas répondu (réseau, clé refusée ou limite atteinte). Réessaie dans un instant.")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            NoopButton("Réessayer", systemImage: "arrow.clockwise", fullWidth: true) {
                                Task { await runAI() }
                            }
                        case .idle:
                            NoopButton("Lancer le débrief IA", systemImage: "sparkles", fullWidth: true) {
                                Task { await runAI() }
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func runAI() async {
        guard let context, aiState != .loading else { return }
        guard CoachBriefScheduler.coachMasterEnabled, coach.isConfigured else { aiState = .notConfigured; return }
        guard coach.dataConsent else { aiState = .noConsent; return }
        aiState = .loading
        let reply = await coach.headlessAnswer(WorkoutDebrief.fullPrompt(context))
        if let reply {
            aiText = reply
            WorkoutDebriefCache.save(reply, for: row)
            aiState = .idle
        } else {
            aiState = .failed
        }
    }

    // MARK: - Load

    @MainActor
    private func load() async {
        let hr = await repo.workoutHrSamples(from: row.startTs, to: row.endTs, source: row.source)
        let zoneSet = profile.hrZoneSet
        let phys = WorkoutPhysiology.analyse(hr: hr, zoneSet: zoneSet)

        let dayKey = Repository.dayString(Date(timeIntervalSince1970: TimeInterval(row.startTs)))
        let day = await repo.dailyMetrics(fromDay: dayKey, toDay: dayKey).first
        let restingHR = Double(day?.restingHr ?? Int(StrainScorer.defaultRestingHR))
        let maxHR = Double(profile.hrMax)
        let substrate = await repo.workoutSubstrateEstimate(
            from: row.startTs, to: row.endTs, maxHR: maxHR, restingHR: restingHR,
            energyKcal: row.energyKcal, source: row.source)
        let durationS = row.durationS ?? Double(row.endTs - row.startTs)
        let refuel = substrate.flatMap {
            WorkoutCarbRefuelEstimator.estimate(substrate: $0, weightKg: profile.weightKg, durationS: durationS)
        }
        let hrr = await repo.workoutHeartRateRecovery(from: row.startTs, to: row.endTs, maxHR: maxHR, source: row.source)

        let now = Int(Date().timeIntervalSince1970)
        let lookback = max(10, (now - row.startTs) / 86_400 + 9)
        let weekStart = row.startTs - 7 * 86_400
        let week = await repo.workoutRows(days: lookback).filter { $0.startTs >= weekStart && $0.startTs < row.startTs }
        let weekMinutes = week.reduce(0.0) { $0 + ($1.durationS ?? Double($1.endTs - $1.startTs)) / 60 }

        physiology = phys
        context = WorkoutDebrief.SessionContext(
            row: row, physiology: phys, customZones: profile.hasCustomHRZones,
            age: profile.age, sex: profile.sex, weightKg: profile.weightKg, day: day,
            substrate: substrate, carbRefuel: refuel, heartRateRecovery: hrr,
            weekSessions: week.count, weekMinutes: weekMinutes)
        loaded = true

        if let cached = WorkoutDebriefCache.load(row) {
            aiText = cached
        } else if CoachBriefScheduler.coachMasterEnabled, coach.isConfigured, coach.dataConsent {
            await runAI()   // first open: debrief straight away, as asked
        } else {
            aiState = coach.isConfigured && CoachBriefScheduler.coachMasterEnabled ? .noConsent : .notConfigured
        }
    }

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(row.startTs)))
    }
}
