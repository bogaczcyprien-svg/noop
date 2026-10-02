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
