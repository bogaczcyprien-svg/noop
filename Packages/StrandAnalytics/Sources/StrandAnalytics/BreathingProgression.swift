import Foundation

// BreathingProgression.swift — levels for the training exercises of the iOS Breathing tab.
//
// Fork addition. Pure. The training drills get harder as the wearer completes them (progressive
// overload, the principle every breath-training protocol uses); the calming drills (coherence, sighing,
// sleep, box, airways) stay as they are, because their dose is the point, not their difficulty.
//
//  • CO2 tolerance 6-6-10: the empty hold grows 10 → 30 s in 5 s steps (apnea "CO2 table" logic: same
//    breathing, longer exposure to the urge to breathe).
//  • Breath-hold series: 5 → 15 holds in steps of 2, the hold cap rising 150 → 300 s; recovery stays at
//    2 minutes for safety. 15 holds is the de Bruijn 2008 protocol that raised EPO.
//  • Respiratory muscle training: 30 → 60 breaths in steps of 5. The studies progress by raising a
//    device's resistance about weekly; the level-up prompt says so for wearers who use one.
//
// A level is earned by completing `sessionsPerLevel` sessions in full (a session stopped early does not
// count). The wearer can step down at any time.

public enum BreathingProgression {

    public struct State: Equatable, Sendable {
        public var level: Int
        /// Full sessions done at this level.
        public var completions: Int
        public init(level: Int = 1, completions: Int = 0) { self.level = level; self.completions = completions }
    }

    public static func isProgressive(_ id: String) -> Bool { maxLevel(id) > 1 }

    public static func maxLevel(_ id: String) -> Int {
        switch id {
        case BreathingScienceCatalog.co2Id: return 5
        case BreathingScienceCatalog.breathHoldsId: return 6
        case BreathingScienceCatalog.respiratoryMuscleId: return 7
        default: return 1
        }
    }

    public static func sessionsPerLevel(_ id: String) -> Int {
        id == BreathingScienceCatalog.respiratoryMuscleId ? 6 : 3
    }

    /// Hold after the exhale for the CO2 drill, seconds.
    public static func co2HoldSeconds(level: Int) -> Int { 10 + 5 * (clamp(level, BreathingScienceCatalog.co2Id) - 1) }

    /// Breath-hold rounds and hold cap, seconds.
    public static func breathHolds(level: Int) -> (rounds: Int, maxHoldSeconds: Int) {
        let l = clamp(level, BreathingScienceCatalog.breathHoldsId) - 1
        return (5 + 2 * l, 150 + 30 * l)
    }

    /// Breaths per respiratory-muscle session.
    public static func muscleBreaths(level: Int) -> Int { 30 + 5 * (clamp(level, BreathingScienceCatalog.respiratoryMuscleId) - 1) }

    /// `base` at `level`. Non-progressive exercises come back unchanged.
    public static func exercise(_ base: BreathingExercise, level: Int) -> BreathingExercise {
        switch base.id {
        case BreathingScienceCatalog.co2Id:
            let hold = co2HoldSeconds(level: level)
            return with(base, guidedSeconds: base.guidedSeconds,
                        drill: .paced([BreathStage(type: .inhale, durationMs: 6_000),
                                       BreathStage(type: .exhale, durationMs: 6_000),
                                       BreathStage(type: .hold, durationMs: hold * 1000, label: "Hold empty")]))
        case BreathingScienceCatalog.breathHoldsId:
            let h = breathHolds(level: level)
            return with(base, guidedSeconds: h.rounds * (120 + h.maxHoldSeconds),
                        drill: .breathHolds(rounds: h.rounds, recoverySeconds: 120, maxHoldSeconds: h.maxHoldSeconds))
        case BreathingScienceCatalog.respiratoryMuscleId:
            let breaths = muscleBreaths(level: level)
            return with(base, guidedSeconds: breaths * 6, drill: base.drill)
        default:
            return base
        }
    }

    /// The state after a session. Only a session completed in full counts; reaching `sessionsPerLevel`
    /// moves to the next level (capped) and resets the count.
    public static func afterSession(_ s: State, id: String, completedFully: Bool) -> (state: State, leveledUp: Bool) {
        guard isProgressive(id), completedFully else { return (s, false) }
        var next = State(level: clamp(s.level, id), completions: s.completions + 1)
        guard next.completions >= sessionsPerLevel(id), next.level < maxLevel(id) else { return (next, false) }
        next = State(level: next.level + 1, completions: 0)
        return (next, true)
    }

    /// One level down (the "too hard" button); the count restarts.
    public static func stepDown(_ s: State, id: String) -> State {
        State(level: max(1, clamp(s.level, id) - 1), completions: 0)
    }

    static func clamp(_ level: Int, _ id: String) -> Int { min(max(level, 1), maxLevel(id)) }

    private static func with(_ b: BreathingExercise, guidedSeconds: Int, drill: BreathingDrill) -> BreathingExercise {
        BreathingExercise(id: b.id, title: b.title, subtitle: b.subtitle, benefits: b.benefits, howTo: b.howTo,
                          evidence: b.evidence, caution: b.caution, guidedSeconds: guidedSeconds, drill: drill)
    }
}
