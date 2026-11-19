import Foundation

// PlannedSessionAdvice.swift — "is today's planned session a good idea given this morning's Charge?"
// Fork addition (not upstream). Pure, deterministic, DB-free.
//
// WELLNESS GUIDANCE ONLY: a nudge to listen to recovery, never a prescription. The session's intensity
// is classified from what intervals.icu gives (planned load, duration, and words in the name/notes),
// then crossed with the Charge band (green ≥ 67, yellow 34–66, red < 34 — the app's own bands).
public enum PlannedSessionAdvice {

    public enum Intensity: String, Sendable { case easy, moderate, hard }
    public enum Level: String, Sendable { case go, adjust, swap }

    public struct Advice: Equatable, Sendable {
        public let level: Level
        public let intensity: Intensity
        public let title: String
        public let detail: String
    }

    static let hardWords = ["interval", "fraction", "vo2", "seuil", "threshold", "sprint", "anaer",
                            "pyramid", "pyramide", "tempo", "race", "test ftp", "ftp",
                            "sweet spot", "sweetspot", "côte", "cote", "hill", "30/30", "40/20"]
    static let easyWords = ["récup", "recup", "recovery", "easy", "facile", "endurance fondamentale",
                            "z1", "z2", "zone 1", "zone 2", "décrass", "decrass", "footing léger"]

    /// Classifies a planned session. Repetition patterns like "5x4'" or "6 x 3 min" count as hard.
    public static func intensity(name: String?, description: String?, durationS: Int?,
                                 load: Double?) -> Intensity {
        let text = ((name ?? "") + " " + (description ?? "")).lowercased()
        if easyWords.contains(where: { text.contains($0) }) { return .easy }
        if hardWords.contains(where: { text.contains($0) }) { return .hard }
        if text.range(of: #"\d+\s?x\s?\d+"#, options: .regularExpression) != nil { return .hard }
        if let load, let d = durationS, d > 0 {
            let perHour = load / (Double(d) / 3_600)
            if perHour >= 75 || load >= 110 { return .hard }
            if perHour >= 55 || load >= 70 { return .moderate }
            return d >= 90 * 60 ? .moderate : .easy
        }
        if let load {
            if load >= 110 { return .hard }
            if load >= 70 { return .moderate }
            return .easy
        }
        if let d = durationS { return d >= 90 * 60 ? .moderate : .easy }
        return .moderate
    }

    /// nil when there is no Charge to judge against.
    public static func advise(charge: Double?, intensity: Intensity) -> Advice? {
        guard let charge else { return nil }
        let c = Int(charge.rounded())
        if charge >= 67 {
            return Advice(level: .go, intensity: intensity,
                          title: "Feu vert",
                          detail: "Charge \(c) % : ton corps est prêt, fais ta séance comme prévu.")
        }
        if charge >= 34 {
            switch intensity {
            case .hard:
                return Advice(level: .adjust, intensity: intensity,
                              title: "Garde-la, mais allège",
                              detail: "Charge \(c) % : fais la séance avec 1 ou 2 répétitions en moins, ou un cran moins fort. Arrête-toi si les jambes ne suivent pas.")
            case .moderate:
                return Advice(level: .go, intensity: intensity,
                              title: "OK, sans forcer",
                              detail: "Charge \(c) % : la séance est raisonnable, reste à l'écoute et ne rajoute rien.")
            case .easy:
                return Advice(level: .go, intensity: intensity,
                              title: "Parfait pour aujourd'hui",
                              detail: "Charge \(c) % : une séance facile, c'est exactement ce qu'il faut.")
            }
        }
        switch intensity {
        case .hard, .moderate:
            return Advice(level: .swap, intensity: intensity,
                          title: "Plutôt du facile aujourd'hui",
                          detail: "Charge \(c) % : ton corps récupère encore. Remplace par 30 à 45 min très facile (zones 1-2), ou repos, et décale la séance prévue.")
        case .easy:
            return Advice(level: .go, intensity: intensity,
                          title: "OK, vraiment tranquille",
                          detail: "Charge \(c) % : la séance facile passe, mais reste bien en zones 1-2.")
        }
    }
}
