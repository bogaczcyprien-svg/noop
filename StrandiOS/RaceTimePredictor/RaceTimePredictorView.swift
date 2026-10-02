#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// Estimated race finish times from the already-computed VO2max estimate. Fork addition — see
/// `RaceTimePredictor`'s header for the two published, non-proprietary relationships it chains and
/// why the result is an approximation, not a guarantee.
struct RaceTimePredictorView: View {
    @EnvironmentObject var repo: Repository

    @State private var vo2max: Double?
    @State private var loaded = false

    var body: some View {
        ScreenScaffold(
            title: "Prédicteur de course",
            subtitle: "Temps estimés à partir de votre VO₂ Max — une approximation, pas une garantie."
        ) {
            if let vo2max {
                StrandCard(padding: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("VO₂ Max")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer()
                            Text("\(Int(vo2max.rounded())) ml/kg/min")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        ForEach(RaceTimePredictor.estimate(vo2max: vo2max), id: \.distance.label) { est in
                            HStack {
                                Text(est.distance.label)
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Text(RaceTimePredictor.formatDuration(est.seconds))
                                    .font(StrandFont.body.monospacedDigit())
                                    .foregroundStyle(StrandPalette.accent)
                            }
                        }
                        Text("Calculé à partir de deux relations publiées en physiologie de l'exercice (équation ACSM pour la course + fraction de VO₂ Max soutenable par distance), pas un modèle propriétaire. Ignore l'allure, le terrain, la météo et l'alimentation du jour — une estimation, pas une prédiction précise.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if loaded {
                StrandCard(padding: 20) {
                    Text("Pas encore de VO₂ Max estimé — portez le bracelet régulièrement et renseignez votre tour de taille dans votre profil pour le débloquer.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ComingSoon(what: "Lecture de votre VO₂ Max…", symbol: "figure.run")
            }
        }
        .task { await load() }
    }

    private func load() async {
        let points = await repo.resolvedSeries(key: "vo2max_est", source: Repository.whoopSource)
        vo2max = points.points.last?.value
        loaded = true
    }
}
#endif
