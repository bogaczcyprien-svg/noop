#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// "Resilience" (fork addition, in the spirit of Oura's score): on your higher-stress days over the
/// last 14, how well did Charge still hold up? Built entirely from the already-stored `stress` and
/// `recovery` daily series — no new sensor, no new engine beyond the small composite in
/// `ResilienceEngine`.
struct ResilienceView: View {
    @EnvironmentObject var repo: Repository

    @State private var result: ResilienceEngine.Result?
    @State private var loaded = false

    var body: some View {
        ScreenScaffold(
            title: "Résilience",
            subtitle: "Sur vos nuits/jours plus stressants, votre Charge tient-elle le coup ?"
        ) {
            if let result {
                StrandCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(bandLabel(result.band))
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Text("\(Int(result.resilienceScore.rounded()))%")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.accent)
                        }
                        Text("Moyenne de Charge sur \(result.higherStressDayCount) jour(s) plus stressant(s) des 14 derniers jours.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if loaded {
                StrandCard(padding: 20) {
                    Text("Pas encore assez de jours avec stress ET Charge mesurés pour un résultat fiable — ça se construit avec le temps.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ComingSoon(what: "Lecture de votre historique…", symbol: "shield.lefthalf.filled")
            }
        }
        .task { await load() }
    }

    private func bandLabel(_ band: ResilienceEngine.Band) -> String {
        switch band {
        case .limited: return "Limitée"
        case .adequate: return "Correcte"
        case .solid: return "Solide"
        case .strong: return "Forte"
        case .exceptional: return "Exceptionnelle"
        }
    }

    private func load() async {
        let stressPts = await repo.exploreSeries(key: "stress", source: Repository.whoopSource)
        let recoveryPts = await repo.exploreSeries(key: "recovery", source: Repository.whoopSource)
        let stressByDay = Dictionary(uniqueKeysWithValues: stressPts.map { ($0.day, $0.value) })
        let recoveryByDay = Dictionary(uniqueKeysWithValues: recoveryPts.map { ($0.day, $0.value) })
        let days = Set(stressByDay.keys).union(recoveryByDay.keys).map {
            ResilienceEngine.DayInput(day: $0, stress: stressByDay[$0], recovery: recoveryByDay[$0])
        }
        result = ResilienceEngine.evaluate(days: days)
        loaded = true
    }
}
#endif
