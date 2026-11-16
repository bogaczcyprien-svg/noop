import Foundation

// BreathingDailyPick.swift — FORK-ONLY, not ported to Android. Today's suggested breathing exercise on
// the Breathing tab, from the morning Charge and the time of day. A plain rule table, no scoring:
//   evening (21:00-04:59)          -> slow 4-8 breathing to wind down for sleep;
//   no Charge yet today            -> cyclic sighing, the quickest calm-down;
//   no resonance pace saved yet    -> find it (daytime, Charge 50+), since three exercises use it;
//   Charge < 34 (low recovery)     -> cardiac coherence 5-5, gentle and calming;
//   Charge 34-66                   -> resonance pace (or coherence 5-5 without a saved pace);
//   Charge 67+ morning / afternoon -> breath-hold series / CO2 tolerance 6-6-10, the demanding ones.
public enum BreathingDailyPick {

    public struct Pick: Equatable, Sendable {
        public let exerciseId: String
        public let reasonFR: String
    }

    public static func pick(charge: Double?, hour: Int, hasResonancePace: Bool) -> Pick {
        let C = BreathingScienceCatalog.self
        if hour >= 21 || hour < 5 {
            return Pick(exerciseId: C.sleepId, reasonFR: "C'est le soir : une respiration lente pour calmer le corps avant de dormir.")
        }
        guard let charge else {
            return Pick(exerciseId: C.cyclicSighId, reasonFR: "Pas encore de Charge aujourd'hui : quelques soupirs cycliques, le moyen le plus rapide de se calmer.")
        }
        let c = Int(charge.rounded())
        if !hasResonancePace && charge >= 50 {
            return Pick(exerciseId: C.resonanceTestId, reasonFR: "Charge \(c) et pas encore de rythme de résonance : c'est le bon jour pour le trouver, il sert à trois exercices.")
        }
        if charge < 34 {
            return Pick(exerciseId: C.coherenceId, reasonFR: "Charge basse (\(c)) : une cohérence cardiaque douce pour aider la récupération, rien de dur.")
        }
        if charge < 67 {
            return hasResonancePace
                ? Pick(exerciseId: C.resonanceId, reasonFR: "Charge moyenne (\(c)) : ton rythme de résonance, pour entretenir sans forcer.")
                : Pick(exerciseId: C.coherenceId, reasonFR: "Charge moyenne (\(c)) : une cohérence cardiaque pour entretenir sans forcer.")
        }
        return hour < 12
            ? Pick(exerciseId: C.breathHoldsId, reasonFR: "Bonne Charge (\(c)) ce matin : tu peux faire les apnées, l'exercice le plus exigeant.")
            : Pick(exerciseId: C.co2Id, reasonFR: "Bonne Charge (\(c)) : un travail de tolérance au CO2 pour progresser.")
    }
}
