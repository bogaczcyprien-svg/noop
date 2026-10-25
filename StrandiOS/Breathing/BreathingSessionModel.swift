#if os(iOS)
import Foundation
import Combine
import UIKit
import StrandAnalytics
import StrandImport

/// One Breathing-tab session (fork addition): an optional free-breathing part (default 10 minutes, the
/// baseline the guided part is compared against), then the guided exercise, then a summary posted to
/// intervals.icu as an activity when an API key is set.
///
/// Heart rate and R-R come from the chest strap when it is connected, else from the WHOOP's live feed.
/// Breathing rate is read from the R-R (`BreathingSignal`); during a paced part, a second without a
/// readable rate falls back to the guided pace, which the wearer is following.
@MainActor
final class BreathingSessionModel: ObservableObject {

    enum Part: Equatable {
        case free
        case guided
        case recovery(round: Int)
        case hold(round: Int)
        case done
    }

    /// What the pacer shows at one instant.
    struct Pacer: Equatable {
        let phase: BreathPhase
        let label: String?
        /// 0 = lungs empty, 1 = full; the circle's size.
        let fill: Double
        let secondsLeft: Int
    }

    struct PartStats: Equatable {
        var seconds = 0
        var avgHR: Double?
        var minHR: Int?
        var avgBreathsPerMin: Double?
        var rmssd: Double?
        var avgCoherence: Double?
    }

    struct Summary: Equatable {
        var free = PartStats()
        var guided = PartStats()
        var holdsSeconds: [Int] = []
        var resonanceBpm: Double?
        var resonanceLocked = false
        var totalSeconds = 0
        var source: String = ""
    }

    enum Upload: Equatable {
        case notConfigured, sending, sent, failed(String)
    }

    let exercise: BreathingExercise
    let freeSeconds: Int

    @Published private(set) var part: Part = .free
    @Published private(set) var partElapsed = 0
    @Published private(set) var totalElapsed = 0
    @Published private(set) var heartRate: Int?
    @Published private(set) var breathsPerMin: Double?
    @Published private(set) var coherence: Double?
    @Published private(set) var rmssd: Double?
    @Published private(set) var holdsSeconds: [Int] = []
    @Published private(set) var summary: Summary?
    @Published private(set) var upload: Upload = .notConfigured

    private let strap: BreathingStrapLink
    private let live: LiveState
    private var startDate = Date()
    private var partStart = Date()
    private var guidedStart: Date?
    private var samples: [BreathingFitExporter.Sample] = []
    /// Which part each sample belongs to: true = guided (holds and recoveries count as guided).
    private var sampleIsGuided: [Bool] = []
    private var coherenceReadings: [(guided: Bool, value: Double)] = []
    private var beats: [(ts: Double, rrMs: Int)] = []
    private var ticker: Timer?
    private var fastTicker: Timer?
    private var liveRRSub: AnyCancellable?
    private var lastStageKey: String?
    private let resonanceBpmAtStart = BiofeedbackPrefs.lockedPace
    private let guidedProtocol: BreathProtocol?

    /// Calm pace between breath holds: 4 s in, 6 s out.
    private static let recoveryStages = [BreathStage(type: .inhale, durationMs: 4_000),
                                         BreathStage(type: .exhale, durationMs: 6_000)]

    init(exercise: BreathingExercise, freeSeconds: Int, strap: BreathingStrapLink, live: LiveState) {
        self.exercise = exercise
        self.freeSeconds = max(0, freeSeconds)
        self.strap = strap
        self.live = live
        self.guidedProtocol = exercise.asProtocol(resonanceBpm: BiofeedbackPrefs.lockedPace)
    }

    // MARK: - Lifecycle

    func start() {
        startDate = Date()
        UIApplication.shared.isIdleTimerDisabled = true
        _ = strap.takeBeats()
        liveRRSub = live.$rrSeq.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.takeLiveRR() }
        }
        if freeSeconds > 0 { enter(.free) } else { startGuided() }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        fastTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.hapticTick() }
        }
    }

    func skipFree() {
        guard part == .free else { return }
        startGuided()
    }

    /// The wearer breathes again: end the current hold.
    func endHold() {
        guard case .hold(let round) = part else { return }
        holdsSeconds.append(partElapsed)
        nextAfterHold(round)
    }

    /// Stop early. A session of at least a minute is still summarised and posted.
    func stop() {
        if case .hold = part { holdsSeconds.append(partElapsed) }
        finish()
    }

    // MARK: - Pacer

    func pacer(at date: Date) -> Pacer? {
        switch part {
        case .free, .done:
            return nil
        case .hold:
            let cap = holdCapSeconds
            return Pacer(phase: .hold, label: "Hold", fill: 1, secondsLeft: max(0, cap - Int(date.timeIntervalSince(partStart))))
        case .recovery:
            return cyclePacer(Self.recoveryStages, elapsedMs: Int(date.timeIntervalSince(partStart) * 1000))
        case .guided:
            guard let g = guidedStart else { return nil }
            let ms = Int(date.timeIntervalSince(g) * 1000)
            if case .resonanceSweep(let perPace) = exercise.drill {
                let paces = ResonanceEngine.fullSweepPaces
                let index = min(paces.count - 1, ms / (perPace * 1000))
                let half = Int((60_000.0 / paces[index] / 2).rounded())
                let stages = [BreathStage(type: .inhale, durationMs: half), BreathStage(type: .exhale, durationMs: half)]
                return cyclePacer(stages, elapsedMs: ms - index * perPace * 1000)
            }
            guard let stages = guidedProtocol?.stages, !stages.isEmpty else { return nil }
            return cyclePacer(stages, elapsedMs: ms)
        }
    }

    /// Current resonance-sweep pace, breaths per minute.
    var sweepPace: Double? {
        guard case .resonanceSweep(let perPace) = exercise.drill, part == .guided, let g = guidedStart else { return nil }
        let paces = ResonanceEngine.fullSweepPaces
        return paces[min(paces.count - 1, Int(Date().timeIntervalSince(g)) / perPace)]
    }

    /// Length of the guided part, seconds (holds: until the last round ends).
    var guidedSeconds: Int {
        switch exercise.drill {
        case .resonanceSweep(let perPace): return perPace * ResonanceEngine.fullSweepPaces.count
        case .breathHolds(let rounds, let recovery, let cap): return rounds * (recovery + cap)
        default: return exercise.guidedSeconds
        }
    }

    private var holdCapSeconds: Int {
        if case .breathHolds(_, _, let cap) = exercise.drill { return cap }
        return 0
    }

    private func cyclePacer(_ stages: [BreathStage], elapsedMs: Int) -> Pacer? {
        let cycle = stages.reduce(0) { $0 + $1.durationMs }
        guard cycle > 0 else { return nil }
        var t = ((elapsedMs % cycle) + cycle) % cycle
        var level = 0.0
        for (i, s) in stages.enumerated() {
            if t < s.durationMs {
                let p = s.durationMs > 0 ? Double(t) / Double(s.durationMs) : 1
                let start = level
                let fill: Double
                switch s.type {
                case .inhale:
                    // A second inhale (a sniff) tops up from where the first one stopped.
                    let target = stages.dropFirst(i + 1).first?.type == .inhale ? 0.8 : 1.0
                    fill = start + (target - start) * p
                case .exhale: fill = start * (1 - p)
                case .hold, .textOnly: fill = start
                }
                return Pacer(phase: s.type, label: s.label, fill: fill,
                             secondsLeft: Int(ceil(Double(s.durationMs - t) / 1000)))
            }
            t -= s.durationMs
            switch s.type {
            case .inhale: level = stages.dropFirst(i + 1).first?.type == .inhale ? 0.8 : 1.0
            case .exhale: level = 0
            case .hold, .textOnly: break
            }
        }
        return nil
    }

    // MARK: - Ticks

    private func tick() {
        guard part != .done else { return }
        let now = Date()
        totalElapsed = Int(now.timeIntervalSince(startDate))
        partElapsed = Int(now.timeIntervalSince(partStart))
        takeStrapBeats()
        heartRate = strap.isConnected ? strap.heartRate : live.heartRate

        if totalElapsed % 5 == 0 { refreshReadings(now: now.timeIntervalSince1970) }
        let guided = part != .free
        var bpm = breathsPerMin
        if case .hold = part { bpm = nil } else if bpm == nil, guided { bpm = guidedPaceNow }
        samples.append(.init(ts: Int(now.timeIntervalSince1970), hr: heartRate, breathsPerMin: bpm))
        sampleIsGuided.append(guided)

        switch part {
        case .free where partElapsed >= freeSeconds:
            startGuided()
        case .guided where partElapsed >= guidedSeconds:
            finish()
        case .recovery(let round):
            if case .breathHolds(_, let recovery, _) = exercise.drill, partElapsed >= recovery { enter(.hold(round: round)) }
        case .hold(let round) where partElapsed >= holdCapSeconds:
            holdsSeconds.append(partElapsed)
            nextAfterHold(round)
        default:
            break
        }
    }

    private var guidedPaceNow: Double? {
        switch exercise.drill {
        case .paced: return exercise.pacedBreathsPerMinute
        case .resonancePaced: return BiofeedbackPrefs.lockedPace ?? ResonanceEngine.fallbackBpm
        case .resonanceSweep: return sweepPace
        case .breathHolds: return 6.0
        }
    }

    private func hapticTick() {
        guard let p = pacer(at: Date()) else { lastStageKey = nil; return }
        let key = "\(p.phase.rawValue)|\(p.label ?? "")|\(part)"
        guard key != lastStageKey else { return }
        let first = lastStageKey == nil
        lastStageKey = key
        guard !first else { return }
        switch p.phase {
        case .inhale: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .exhale: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .hold, .textOnly: UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }

    private func refreshReadings(now: Double) {
        let window = beats.filter { $0.ts > now - 64 }.map { Double($0.rrMs) }
        breathsPerMin = BreathingSignal.breathsPerMinute(rrMs: window)
        coherence = BreathingSignal.coherence(rrMs: window)
        rmssd = HRVAnalyzer.rmssdRaw(HRVAnalyzer.cleanRR(window))
        if let c = coherence, part != .free { coherenceReadings.append((guided: true, value: c)) }
        if let c = coherence, part == .free { coherenceReadings.append((guided: false, value: c)) }
    }

    private func takeStrapBeats() {
        guard strap.isConnected else { return }
        beats.append(contentsOf: strap.takeBeats())
    }

    private func takeLiveRR() {
        guard !strap.isConnected, part != .done else { return }
        let now = Date().timeIntervalSince1970
        var t = now
        var batch: [(ts: Double, rrMs: Int)] = []
        for rr in live.rr.reversed() where rr > 0 {
            batch.append((ts: t, rrMs: rr))
            t -= Double(rr) / 1000
        }
        beats.append(contentsOf: batch.reversed())
    }

    // MARK: - Parts

    private func enter(_ p: Part) {
        part = p
        partStart = Date()
        partElapsed = 0
    }

    private func startGuided() {
        guidedStart = Date()
        if case .breathHolds = exercise.drill { enter(.recovery(round: 1)) } else { enter(.guided) }
    }

    private func nextAfterHold(_ round: Int) {
        if case .breathHolds(let rounds, _, _) = exercise.drill, round < rounds {
            enter(.recovery(round: round + 1))
        } else {
            finish()
        }
    }

    private func finish() {
        guard part != .done else { return }
        ticker?.invalidate(); fastTicker?.invalidate()
        liveRRSub = nil
        UIApplication.shared.isIdleTimerDisabled = false
        takeStrapBeats()
        let end = Date()
        part = .done
        var s = Summary()
        s.totalSeconds = Int(end.timeIntervalSince(startDate))
        s.holdsSeconds = holdsSeconds
        s.source = strap.isConnected ? (strap.strapName ?? String(localized: "Chest strap")) : "WHOOP"
        let guidedFrom = guidedStart?.timeIntervalSince1970 ?? end.timeIntervalSince1970
        s.free = stats(guided: false, beatsFrom: startDate.timeIntervalSince1970, to: guidedFrom)
        s.guided = stats(guided: true, beatsFrom: guidedFrom, to: end.timeIntervalSince1970)
        if case .resonanceSweep(let perPace) = exercise.drill, let g = guidedStart {
            let result = sweepResult(guidedStart: g.timeIntervalSince1970, perPace: perPace)
            s.resonanceBpm = result.lockedBpm
            s.resonanceLocked = result.didLock
            if result.didLock { BiofeedbackPrefs.saveLockedPace(result.lockedBpm, date: end) }
        }
        summary = s
        guard s.totalSeconds >= 60 else { return }
        Task { await post(summary: s, end: end) }
    }

    private func stats(guided: Bool, beatsFrom: Double, to: Double) -> PartStats {
        var out = PartStats()
        let rows = zip(samples, sampleIsGuided).filter { $0.1 == guided }.map(\.0)
        out.seconds = rows.count
        let hrs = rows.compactMap(\.hr)
        out.avgHR = hrs.isEmpty ? nil : Double(hrs.reduce(0, +)) / Double(hrs.count)
        out.minHR = hrs.min()
        let rr = beats.filter { $0.ts >= beatsFrom && $0.ts < to }.map { Double($0.rrMs) }
        out.rmssd = HRVAnalyzer.rmssdRaw(HRVAnalyzer.cleanRR(rr))
        let resp = rows.compactMap(\.breathsPerMin)
        out.avgBreathsPerMin = resp.isEmpty ? nil : resp.reduce(0, +) / Double(resp.count)
        let coh = coherenceReadings.filter { $0.guided == guided }.map(\.value)
        out.avgCoherence = coh.isEmpty ? nil : coh.reduce(0, +) / Double(coh.count)
        return out
    }

    private func sweepResult(guidedStart: Double, perPace: Int) -> ResonanceEngine.SweepResult {
        let paces = ResonanceEngine.fullSweepPaces
        let samples = paces.enumerated().map { i, bpm -> ResonanceEngine.PaceSample in
            let from = guidedStart + Double(i * perPace)
            let to = from + Double(perPace)
            let rr = beats.filter { $0.ts >= from && $0.ts < to }
                .map { ResonanceEngine.RrBeat(ts: Int($0.ts), rrMs: $0.rrMs) }
            return ResonanceEngine.PaceSample(bpm: bpm, rr: rr, startTs: Int(from), endTs: Int(to))
        }
        return ResonanceEngine.sweep(samples)
    }

    // MARK: - intervals.icu

    private func post(summary s: Summary, end: Date) async {
        let settings = IntervalsICUSettings.shared
        guard let key = settings.apiKey(), !key.isEmpty else { upload = .notConfigured; return }
        upload = .sending
        let startTs = Int(startDate.timeIntervalSince1970)
        let fit = BreathingFitExporter.build(samples: samples, rrMs: beats.map(\.rrMs),
                                             startTs: startTs, endTs: Int(end.timeIntervalSince1970))
        let title = BreathingL10n.text(exercise.title)
        let name = String(localized: "Breathing · \(title)")
        do {
            try await IntervalsICUClient(athleteId: settings.athleteId, apiKey: key)
                .uploadActivity(fit: fit, filename: "noop-breathing-\(startTs).fit", name: name,
                                description: BreathingSessionText.description(s, exercise: exercise))
            upload = .sent
        } catch IntervalsICUError.http(let code) {
            upload = .failed("HTTP \(code)")
        } catch {
            upload = .failed(error.localizedDescription)
        }
    }

    /// Re-send after a failure.
    func retryUpload() {
        guard let s = summary, case .failed = upload else { return }
        Task { await post(summary: s, end: startDate.addingTimeInterval(TimeInterval(s.totalSeconds))) }
    }
}

/// The activity description posted with a session: plain lines, one figure each.
enum BreathingSessionText {
    static func description(_ s: BreathingSessionModel.Summary, exercise: BreathingExercise) -> String {
        var lines: [String] = []
        lines.append(BreathingL10n.text(exercise.title))
        lines.append(String(localized: "Heart data: \(s.source)"))
        lines.append(partLine(String(localized: "Free breathing"), s.free))
        lines.append(partLine(String(localized: "Exercise"), s.guided))
        if !s.holdsSeconds.isEmpty {
            let list = s.holdsSeconds.map { "\($0) s" }.joined(separator: ", ")
            lines.append(String(localized: "Breath holds: \(list)"))
        }
        if let bpm = s.resonanceBpm {
            let pace = String(format: "%.1f", bpm)
            lines.append(s.resonanceLocked
                         ? String(localized: "Resonance pace found: \(pace) breaths/min")
                         : String(localized: "Resonance pace unclear, kept \(pace) breaths/min"))
        }
        lines.append(String(localized: "Breathing rate is read from the heartbeat (RSA); during guided breathing, the guided pace fills gaps."))
        lines.append("NOOP")
        return lines.joined(separator: "\n")
    }

    static func partLine(_ name: String, _ p: BreathingSessionModel.PartStats) -> String {
        var bits: [String] = ["\(name) (\(p.seconds / 60) min \(p.seconds % 60) s)"]
        if let v = p.avgHR { bits.append(String(localized: "HR \(Int(v.rounded())) bpm")) }
        if let v = p.avgBreathsPerMin { bits.append(String(localized: "breathing \(String(format: "%.1f", v))/min")) }
        if let v = p.rmssd { bits.append(String(localized: "RMSSD \(Int(v.rounded())) ms")) }
        if let v = p.avgCoherence { bits.append(String(localized: "coherence \(Int(v.rounded()))/100")) }
        return bits.joined(separator: " · ")
    }
}
#endif
