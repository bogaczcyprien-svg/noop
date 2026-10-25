import Foundation

// BreathingScienceCatalog.swift — the evidence-led exercise list of the iOS Breathing tab.
//
// Fork addition. Each entry says what the research actually supports, in plain words, including where
// the evidence is thin. Strings are English source for `String(localized:)`; the view localizes them.
// Pure data; the session player is `BreathProtocolPlayer` for paced drills.

/// How an exercise runs.
public enum BreathingDrill: Equatable, Sendable {
    /// A fixed breath cycle repeated for the exercise length.
    case paced([BreathStage])
    /// Paced at the wearer's own resonance pace (`ResonanceEngine` result), 5.5/min until one is found.
    case resonancePaced
    /// The resonance sweep: each pace in `ResonanceEngine.fullSweepPaces` for `secondsPerPace`.
    case resonanceSweep(secondsPerPace: Int)
    /// Breath-hold rounds: `recoverySeconds` of calm paced breathing, then a hold the wearer ends by
    /// tapping, capped at `maxHoldSeconds`.
    case breathHolds(rounds: Int, recoverySeconds: Int, maxHoldSeconds: Int)
}

/// One exercise of the Breathing tab.
public struct BreathingExercise: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String
    /// What it does for the wearer, in a few short points.
    public let benefits: [String]
    /// How to do it.
    public let howTo: String
    /// What the research shows, honestly.
    public let evidence: String
    public let caution: String?
    /// Default length of the guided part, seconds (the drill decides for sweeps and hold rounds).
    public let guidedSeconds: Int
    public let drill: BreathingDrill

    public init(id: String, title: String, subtitle: String, benefits: [String] = [], howTo: String, evidence: String,
                caution: String? = nil, guidedSeconds: Int, drill: BreathingDrill) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.benefits = benefits; self.howTo = howTo
        self.evidence = evidence; self.caution = caution; self.guidedSeconds = guidedSeconds
        self.drill = drill
    }

    /// Breaths per minute the drill paces at, when it is a fixed cycle with at least one breath.
    public var pacedBreathsPerMinute: Double? {
        guard case .paced(let stages) = drill else { return nil }
        let cycleMs = stages.reduce(0) { $0 + $1.durationMs }
        let breaths = stages.filter { $0.type == .inhale }.count
        guard cycleMs > 0, breaths > 0 else { return nil }
        // A double inhale (the cyclic sigh) is still one breath.
        let perCycle = id == BreathingScienceCatalog.cyclicSighId ? 1 : breaths
        return Double(perCycle) * 60_000.0 / Double(cycleMs)
    }

    /// The same exercise as a `BreathProtocol`, so `BreathProtocolPlayer` can schedule its cues.
    public func asProtocol(resonanceBpm: Double? = nil) -> BreathProtocol? {
        let stages: [BreathStage]
        switch drill {
        case .paced(let s):
            stages = s
        case .resonancePaced:
            let bpm = resonanceBpm ?? ResonanceEngine.fallbackBpm
            let halfMs = Int((60_000.0 / bpm / 2.0).rounded())
            stages = [BreathStage(type: .inhale, durationMs: halfMs), BreathStage(type: .exhale, durationMs: halfMs)]
        case .resonanceSweep, .breathHolds:
            return nil
        }
        return BreathProtocol(id: id, title: title, subtitle: subtitle, edu: howTo, caution: caution,
                              mode: .playable, category: .ans, recommendedDurationMs: guidedSeconds * 1000,
                              stages: stages)
    }
}

public enum BreathingScienceCatalog {

    public static let coherenceId = "science_coherence_5_5"
    public static let resonanceId = "science_resonance_paced"
    public static let resonanceTestId = "science_resonance_test"
    public static let cyclicSighId = "science_cyclic_sigh"
    public static let co2Id = "science_6_6_10"
    public static let breathHoldsId = "science_breath_holds"
    public static let respiratoryMuscleId = "science_respiratory_muscle"
    public static let airwaysId = "science_airways_humming"
    public static let sleepId = "science_sleep_4_8"
    public static let boxId = "science_box_4_4_4_4"

    /// Bedtime nudge suggestion.
    public static let bedtimeId = coherenceId

    public static func exercise(_ id: String) -> BreathingExercise? { all.first { $0.id == id } }

    public static let all: [BreathingExercise] = [
        BreathingExercise(
            id: coherenceId,
            title: "Cardiac coherence 5-5",
            subtitle: "5 s in · 5 s out · 6 breaths/min",
            benefits: ["Calms stress and anxiety within minutes", "Raises heart-rate variability during the session", "Lowers heart rate and blood pressure a little", "In the evening, helps you fall asleep"],
            howTo: "Breathe in through the nose for 5 seconds, out for 5 seconds, without pausing. Let the belly move more than the chest.",
            evidence: "Best supported. Breathing near 6 per minute lines up breathing and heart rhythm (resonance) and raises heart-rate variability during the session. Reviews of HRV biofeedback find moderate reductions in stress and anxiety (Goessl 2017, Lehrer 2014).",
            guidedSeconds: 5 * 60,
            drill: .paced([BreathStage(type: .inhale, durationMs: 5_000), BreathStage(type: .exhale, durationMs: 5_000)])),
        BreathingExercise(
            id: resonanceTestId,
            title: "Find my resonance pace",
            subtitle: "Test 6 paces · 2 min each",
            benefits: ["Finds the breathing pace that suits your body best", "Makes every coherence session more effective"],
            howTo: "Follow each pace from 4.5 to 7 breaths per minute. The app keeps the one where your heart swings the most with your breath. Do it once with the chest strap; redo it every few months.",
            evidence: "The resonance protocol of Lehrer and Vaschillo: each person has a pace, usually between 4.5 and 7 per minute, where heart-rate oscillations are largest. A chest strap's beat-to-beat data is what makes it measurable.",
            guidedSeconds: 12 * 60,
            drill: .resonanceSweep(secondsPerPace: 120)),
        BreathingExercise(
            id: resonanceId,
            title: "Coherence at my pace",
            subtitle: "Your resonance pace · 5 min",
            benefits: ["The strongest calming effect, at your own pace", "Trains the reflex that steadies blood pressure (baroreflex)", "Same benefits as cardiac coherence, a bit stronger"],
            howTo: "Equal breaths in and out at the pace your resonance test found. Until you take the test, it uses 5.5 per minute.",
            evidence: "Same evidence as cardiac coherence, at the pace that gives you the biggest effect.",
            guidedSeconds: 5 * 60,
            drill: .resonancePaced),
        BreathingExercise(
            id: cyclicSighId,
            title: "Cyclic sighing",
            subtitle: "2 sniffs in · 1 long sigh out",
            benefits: ["Improves mood with 5 minutes a day", "Releases tension quickly", "Over the weeks, lowers your breathing rate at rest"],
            howTo: "Breathe in through the nose, then take a second short sniff to fill the lungs fully, then breathe out slowly through the mouth, as long as you can.",
            evidence: "In a randomised trial, 5 minutes a day of cyclic sighing improved mood and lowered breathing rate at rest more than mindfulness meditation did (Balban, Cell Reports Medicine 2023).",
            guidedSeconds: 5 * 60,
            drill: .paced([BreathStage(type: .inhale, durationMs: 2_000, label: "Inhale"),
                           BreathStage(type: .inhale, durationMs: 1_000, label: "Sniff"),
                           BreathStage(type: .exhale, durationMs: 6_000, label: "Long sigh out")])),
        BreathingExercise(
            id: co2Id,
            title: "Strengthening 6-6-10",
            subtitle: "6 s in · 6 s out · hold 10 s",
            benefits: ["Builds tolerance to the urge to breathe (CO2)", "Trains staying calm when short of air, useful in effort and stress", "Slows your breathing down"],
            howTo: "Breathe in 6 seconds, out 6 seconds, then stay empty before the next breath: 10 seconds at level 1, longer as you level up. Relax during the hold; a mild air hunger is normal.",
            evidence: "Short holds after the exhale train tolerance to carbon dioxide, the urge to breathe. Evidence for performance gains is limited; it is a calm, safe CO2-tolerance drill.",
            caution: "Stop and breathe normally if you feel dizzy.",
            guidedSeconds: 5 * 60,
            drill: .paced([BreathStage(type: .inhale, durationMs: 6_000),
                           BreathStage(type: .exhale, durationMs: 6_000),
                           BreathStage(type: .hold, durationMs: 10_000, label: "Hold empty")])),
        BreathingExercise(
            id: breathHoldsId,
            title: "Breath-hold series",
            subtitle: "5 holds · 2 min rest between",
            benefits: ["May raise natural EPO for a few hours", "Trains tolerance to low oxygen and to CO2", "No proven gain in race time"],
            howTo: "Lying or seated. Breathe calmly for 2 minutes, take one normal breath in, then hold. Tap when you breathe again. The number of rounds grows with your level. Do not hyperventilate before a hold.",
            evidence: "Repeated breath holds can raise natural EPO for a few hours (de Bruijn 2008: +24% after 15 maximal holds), but studies disagree and none shows it makes you faster in a race. Hyperventilating first adds no benefit and can make you black out without warning.",
            caution: "Never in water, in the bath, or while driving. Always lying or seated. Stop at any dizziness. Not if pregnant or with a heart condition.",
            guidedSeconds: 15 * 60,
            drill: .breathHolds(rounds: 5, recoverySeconds: 120, maxHoldSeconds: 150)),
        BreathingExercise(
            id: respiratoryMuscleId,
            title: "Respiratory muscle training",
            subtitle: "30 strong breaths · twice a day",
            benefits: ["Stronger breathing muscles, the diaphragm first", "Less breathlessness in hard efforts", "A small gain in endurance performance", "Lung size itself does not change"],
            howTo: "Breathe in hard and fast, as deep as you can, then let the air out slowly. 30 breaths at level 1, more as you level up, morning and evening. With an inspiratory trainer (a valve device), set it near half of your maximum effort: that is the version the studies use.",
            evidence: "Lung size barely changes with training in healthy adults; what improves is the strength of the breathing muscles. Inspiratory muscle training with a device raises their strength by about 20-30% in 6 weeks and modestly helps endurance performance (Illi 2012, HajGhanbari 2013). Without a device the effect is smaller.",
            caution: "Stop if you feel dizzy or get a headache.",
            guidedSeconds: 3 * 60,
            drill: .paced([BreathStage(type: .inhale, durationMs: 2_000, label: "Strong in"),
                           BreathStage(type: .exhale, durationMs: 4_000, label: "Slow out")])),
        BreathingExercise(
            id: airwaysId,
            title: "Open the airways",
            subtitle: "Nose in · humming out · lips pursed",
            benefits: ["Breathing feels more open and free", "More nitric oxide in the nose, thanks to humming", "Pursed lips keep the airways open longer", "Not a treatment for asthma"],
            howTo: "Breathe in through the nose for 4 seconds, then breathe out for 8 seconds while humming with the mouth closed (mmm). Every fourth breath, breathe in deeply and breathe out through pursed lips.",
            evidence: "Humming raises nitric oxide in the nose about 15-fold (Weitzberg 2002); nitric oxide relaxes airway and vessel walls. Breathing out through pursed lips keeps the airways open longer, and deep breaths stretch the bronchi. Helps the feeling of open breathing; it is not a treatment.",
            caution: "With asthma, keep your inhaler and your treatment; this does not replace them.",
            guidedSeconds: 5 * 60,
            drill: .paced([BreathStage(type: .inhale, durationMs: 4_000), BreathStage(type: .exhale, durationMs: 8_000, label: "Hum out"),
                           BreathStage(type: .inhale, durationMs: 4_000), BreathStage(type: .exhale, durationMs: 8_000, label: "Hum out"),
                           BreathStage(type: .inhale, durationMs: 4_000), BreathStage(type: .exhale, durationMs: 8_000, label: "Hum out"),
                           BreathStage(type: .inhale, durationMs: 5_000, label: "Deep in"),
                           BreathStage(type: .exhale, durationMs: 8_000, label: "Pursed lips out")])),
        BreathingExercise(
            id: sleepId,
            title: "Fall asleep 4-8",
            subtitle: "4 s in · 8 s out · 5 breaths/min",
            benefits: ["Slows the body down before sleep", "May shorten the time it takes to fall asleep", "Calms the mind in bed"],
            howTo: "In bed, lights off. Breathe in 4 seconds through the nose and out 8 seconds, slowly. Let the exhale be passive.",
            evidence: "Slow breathing with a long exhale raises parasympathetic (rest) activity. Small trials before bed found it shortened the time to fall asleep and improved sleep quality (Tsai 2015, Laborde 2019).",
            guidedSeconds: 5 * 60,
            drill: .paced([BreathStage(type: .inhale, durationMs: 4_000), BreathStage(type: .exhale, durationMs: 8_000)])),
        BreathingExercise(
            id: boxId,
            title: "Box breathing 4-4-4-4",
            subtitle: "In 4 · hold 4 · out 4 · hold 4",
            benefits: ["Helps you focus under pressure", "Slows your breathing down", "Easy to remember, to do anywhere"],
            howTo: "Breathe in 4 seconds, hold 4, breathe out 4, hold 4. Even counts, no force.",
            evidence: "Used by the military for focus under stress. Evidence is weaker than for coherence breathing; it slows breathing to about 4 per minute and works as a focus drill.",
            guidedSeconds: 5 * 60,
            drill: .paced([BreathStage(type: .inhale, durationMs: 4_000), BreathStage(type: .hold, durationMs: 4_000, label: "Hold full"),
                           BreathStage(type: .exhale, durationMs: 4_000), BreathStage(type: .hold, durationMs: 4_000, label: "Hold empty")])),
    ]
}
