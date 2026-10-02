import Foundation

// NightExplainer.swift — fork addition (not upstream). Assembles a ONE-SENTENCE "likely contributor"
// from signals NOOP already has (logged Journal entries, HRV/resting-HR deviation from the personal
// baseline) — no new model, a readable summary of existing data. Only ever names what was actually
// logged or measured; never guesses a cause nothing in the data supports.
public enum NightExplainer {
    /// Personal-sigma a metric must clear to be worth naming as a contributor — a small, ordinary
    /// night-to-night wobble isn't "why" anything.
    public static let notableZThreshold = 1.0

    /// `loggedFactors`: Journal questions answered YES for the day the night started (verbatim
    /// canonical strings — the caller decides which ones are worth surfacing, e.g. excluding
    /// positive-framed ones like "Did you read before bed?"). `hrvZ`/`rhrZ`: the night's deviation
    /// from the personal baseline, same sign convention as `RecoveryScorer` (negative HRV z = below
    /// baseline = bad; positive RHR z = below baseline = good, so a NEGATIVE rhrZ is the bad direction
    /// here). Returns nil when nothing logged and nothing notably deviated — an honest "nothing stood
    /// out" rather than a forced explanation.
    public static func explain(loggedFactors: [String], hrvZ: Double?, rhrZ: Double?) -> String? {
        var parts: [String] = []
        parts.append(contentsOf: loggedFactors)

        if let hrvZ, hrvZ <= -notableZThreshold {
            parts.append("une HRV sous votre habitude")
        }
        if let rhrZ, rhrZ <= -notableZThreshold {
            parts.append("une FC de repos au-dessus de votre habitude")
        }

        guard !parts.isEmpty else { return nil }
        if parts.count == 1 {
            return "Possible facteur : \(parts[0])."
        }
        let allButLast = parts.dropLast().joined(separator: ", ")
        return "Possibles facteurs : \(allButLast) et \(parts.last!)."
    }
}
