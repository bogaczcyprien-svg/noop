import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// Builds the AI Coach prompt for a single imported activity (currently: the intervals.icu Activities
/// screen). Pure text formatting — no new stored/scored signal. The %HRR zone-time split below lives
/// only inside this one prompt, the same on-the-fly-derived-text idiom as
/// `AICoachEngine.stressIndexLine()`'s Baevsky summary: it informs what the MODEL says back, it is
/// never written to the store or shown as its own NOOP score.
enum WorkoutDebrief {
    /// Karvonen %HRR band edges, highest-first. A standard, public 5-zone convention (not WHOOP's),
    /// close to the Edwards bands `StrainScorer` uses internally for Effort — but `StrainScorer`'s own
    /// zone table is package-internal, so this is reimplemented here rather than exposed from it.
    private static let bands: [(lo: Double, label: String)] = [
        (90, "Z5 anaérobie (90-100%+ RFC)"),
        (80, "Z4 seuil (80-90% RFC)"),
        (70, "Z3 aérobie soutenu (70-80% RFC)"),
        (60, "Z2 aérobie (60-70% RFC)"),
        (50, "Z1 facile (50-60% RFC)")
    ]
    private static let belowLabel = "< Z1 (sous 50% RFC)"

    /// Time-in-band percentages over `hr`, via Karvonen %HRR = (bpm − restingHR) / (maxHR − restingHR).
    /// nil on degenerate input (no samples, or maxHR ≤ restingHR) — never a fabricated split. Bands with
    /// zero samples are omitted rather than printed as "0%".
    static func zoneBreakdown(hr: [HRSample], restingHR: Double, maxHR: Double) -> [(label: String, pct: Double)]? {
        guard !hr.isEmpty, maxHR > restingHR else { return nil }
        let reserve = maxHR - restingHR
        var counts: [String: Int] = [:]
        for s in hr {
            let pct = (Double(s.bpm) - restingHR) / reserve * 100
            let label = bands.first(where: { pct >= $0.lo })?.label ?? belowLabel
            counts[label, default: 0] += 1
        }
        let total = Double(hr.count)
        let order = bands.map(\.label) + [belowLabel]
        return order.compactMap { label in
            guard let c = counts[label], c > 0 else { return nil }
            return (label, Double(c) / total * 100)
        }
    }

    /// The full user-turn prompt for one activity's debrief — stats + zone breakdown + the ask, all in
    /// one self-contained message (no system-prompt override needed). In French, matching the
    /// Activities screen the button lives on.
    static func prompt(activity: WorkoutRow, zones: [(label: String, pct: Double)]?) -> String {
        var lines: [String] = ["Voici une séance que je viens de terminer :"]
        lines.append("- Sport : \(activity.sport)")
        if let d = activity.durationS { lines.append("- Durée : \(Int(d / 60)) min") }
        if let dist = activity.distanceM { lines.append("- Distance : \(String(format: "%.1f", dist / 1_000)) km") }
        if let avg = activity.avgHr { lines.append("- FC moyenne : \(avg) bpm") }
        if let maxBpm = activity.maxHr { lines.append("- FC max : \(maxBpm) bpm") }
        if let kcal = activity.energyKcal { lines.append("- Calories : \(Int(kcal.rounded())) kcal") }
        if let zones, !zones.isEmpty {
            lines.append("- Répartition du temps par zone (% réserve de FC, Karvonen) :")
            for z in zones { lines.append("  • \(z.label) : \(String(format: "%.0f", z.pct))%") }
        } else {
            lines.append("- (Pas de trace FC détaillée disponible, seulement la FC moyenne/max ci-dessus.)")
        }
        lines.append("")
        lines.append("""
        Débrief cette séance : explique la part aérobie vs anaérobie de l'effort, ce que ça dit de \
        l'intensité réelle par rapport à ce que je visais, et donne-moi un conseil concret pour la \
        prochaine sortie. Réponds en français, de façon concise.
        """)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Full-page debrief (FORK-ONLY, not ported to Android)

extension WorkoutDebrief {

    /// Everything the per-session debrief page knows about one session, for the AI prompt.
    struct SessionContext {
        let row: WorkoutRow
        let physiology: WorkoutPhysiology.Result?
        let customZones: Bool
        let age: Int
        let sex: String
        let weightKg: Double
        /// The session day's scored metrics (morning Charge, last night's sleep, HRV, the day's Effort).
        let day: DailyMetric?
        let substrate: SubstrateEstimator.SubstrateEstimate?
        let carbRefuel: WorkoutCarbRefuel?
        let heartRateRecovery: HeartRateRecovery.Result?
        /// Sessions in the 7 days before this one: count and total minutes.
        let weekSessions: Int
        let weekMinutes: Double
    }

    private static func n0(_ v: Double) -> String { String(Int(v.rounded())) }
    private static func n1(_ v: Double) -> String { String(format: "%.1f", v) }

    /// The full user-turn prompt for the debrief page: the session, its zones and effect estimates, the
    /// day's readiness and the past week, then the ask. French, like the page.
    static func fullPrompt(_ c: SessionContext) -> String {
        let r = c.row
        var l: [String] = ["Voici une séance que j'ai faite. Fais-m'en le débrief."]
        l.append("")
        l.append("SÉANCE")
        l.append("- Sport : \(WorkoutSource.displaySport(r.sport))")
        let durS = r.durationS ?? Double(r.endTs - r.startTs)
        l.append("- Durée : \(n0(durS / 60)) min")
        if let d = r.distanceM, d > 0 { l.append("- Distance : \(n1(d / 1_000)) km") }
        if let a = r.avgHr { l.append("- FC moyenne : \(a) bpm") }
        if let m = r.maxHr { l.append("- FC max : \(m) bpm") }
        if let k = r.energyKcal { l.append("- Calories : \(n0(k)) kcal") }
        if let s = r.strain { l.append("- Effort NOOP de la séance : \(n0(s))/100") }

        if let p = c.physiology {
            l.append("")
            l.append("ZONES CARDIAQUES (\(c.customZones ? "zones personnelles réglées par moi" : "zones par défaut en % de la FC max"), FC max \(n0(p.maxHRUsed)) bpm)")
            let b = p.zoneLowerBoundsBPM
            l.append("- Début des zones 1 à 5 : " + b.map { n0($0) }.joined(separator: " / ") + " bpm")
            let names = ["Sous la zone 1", "Zone 1", "Zone 2", "Zone 3", "Zone 4", "Zone 5"]
            for z in [1, 2, 3, 4, 5, 0] where p.zoneMinutes[z] > 0 {
                l.append("- \(names[z]) : \(n1(p.zoneMinutes[z])) min")
            }
            l.append("")
            l.append("ESTIMATIONS NOOP (calculées depuis la FC, approximatives, ce ne sont pas les chiffres Garmin/Firstbeat)")
            l.append("- Effet aérobie : \(n1(p.aerobicEffect))/5 (\(WorkoutPhysiology.effectLabelFR(p.aerobicEffect)))")
            l.append("- Effet anaérobie : \(n1(p.anaerobicEffect))/5 (\(WorkoutPhysiology.effectLabelFR(p.anaerobicEffect)))")
            l.append("- Bénéfice principal : \(p.benefit.labelFR)")
            l.append("- Temps au-dessus du seuil anaérobie estimé (milieu de la zone 4) : \(n0(p.anaerobicSharePct)) %")
            l.append("- Efforts durs (30 s ou plus au-dessus de ce seuil) : \(p.hardEfforts)")
            if let pk = p.peak60sHR { l.append("- Meilleure minute : \(n0(pk)) bpm de moyenne") }
            if let d = p.driftPct { l.append("- Dérive cardiaque (2e moitié vs 1re) : \(d >= 0 ? "+" : "")\(n1(d)) %") }
        } else {
            l.append("- (Pas de trace cardiaque détaillée pour cette séance.)")
        }
        if let s = c.substrate {
            l.append("- Carburant estimé : \(n0(s.fatPct)) % graisses, \(n0(s.carbPct)) % glucides")
        }
        if let cr = c.carbRefuel {
            l.append("- Glucides à reprendre conseillés : \(n0(cr.refuelTargetG)) g dans les \(n0(cr.windowHours)) h")
        }
        if let h = c.heartRateRecovery, let one = h.after1Minute {
            l.append("- Récupération cardiaque : −\(one) bpm en 1 min après la fin")
        }

        l.append("")
        l.append("MOI ET MA FORME CE JOUR-LÀ")
        if c.age > 0 { l.append("- Âge : \(c.age) ans") }
        if !c.sex.isEmpty { l.append("- Sexe : \(c.sex == "male" ? "homme" : c.sex == "female" ? "femme" : c.sex)") }
        if c.weightKg > 0 { l.append("- Poids : \(n0(c.weightKg)) kg") }
        if let d = c.day {
            if let v = d.recovery { l.append("- Charge (récupération) du matin : \(n0(v))/100") }
            if let v = d.totalSleepMin { l.append("- Sommeil de la nuit d'avant : \(Int(v) / 60) h \(String(format: "%02d", Int(v) % 60))") }
            if let v = d.avgHrv { l.append("- VFC de la nuit : \(n0(v)) ms") }
            if let v = d.restingHr { l.append("- FC de repos : \(v) bpm") }
            if let v = d.strain { l.append("- Effort total de la journée : \(n0(v))/100") }
        }
        l.append("- Les 7 jours d'avant : \(c.weekSessions) séance(s), \(n0(c.weekMinutes)) min au total")

        l.append("")
        l.append("""
        Fais un débrief clair et concret, en français, avec ces parties (titres ###) :
        ### En bref
        Deux ou trois phrases : quel type de séance c'était vraiment et si elle a bien servi.
        ### Ce que ça a fait à ton corps
        Explique physiologiquement, en t'appuyant sur MES chiffres : l'effet aérobie (cœur, volume \
        d'éjection, mitochondries, capillaires, utilisation des graisses, endurance) et l'effet anaérobie \
        (glycolyse, lactate, tolérance à l'acidité, puissance, VO2max). Dis lequel domine et pourquoi.
        ### Fatigue et récupération
        La fatigue probable vu ma forme du jour, combien de temps récupérer avant une séance dure, quoi \
        manger et boire (utilise les glucides conseillés si donnés), et le sommeil.
        ### Pour la prochaine séance
        Un ou deux conseils précis (type de séance, zones, durée).
        Reste simple, sans jargon inutile. Tu n'es pas médecin : pas de diagnostic.
        """)
        return l.joined(separator: "\n")
    }
}

/// FORK-ONLY: the last AI debriefs, kept on the device so reopening a session does not ask the AI again.
/// Keyed by the session's natural key (source + start time); the 60 most recent are kept.
enum WorkoutDebriefCache {
    private static let key = "workoutDebrief.cache.v1"
    private static let maxEntries = 60

    static func id(for row: WorkoutRow) -> String { "\(row.source)|\(row.startTs)" }

    static func load(_ row: WorkoutRow) -> String? {
        (UserDefaults.standard.dictionary(forKey: key)?[id(for: row)] as? [String: Any])?["text"] as? String
    }

    static func save(_ text: String, for row: WorkoutRow) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[id(for: row)] = ["text": text, "at": Date().timeIntervalSince1970]
        if all.count > maxEntries {
            let oldest = all.sorted {
                (($0.value as? [String: Any])?["at"] as? Double ?? 0) < (($1.value as? [String: Any])?["at"] as? Double ?? 0)
            }
            for (k, _) in oldest.prefix(all.count - maxEntries) { all.removeValue(forKey: k) }
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}
