#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// Full-screen session: the breathing circle, the live heart readings, and the summary at the end.
struct BreathingSessionView: View {
    @ObservedObject var model: BreathingSessionModel
    let onClose: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            StrandPalette.surfaceBase.ignoresSafeArea()
            if let s = model.summary {
                summary(s)
            } else {
                running
            }
        }
    }

    // MARK: - Running

    private var running: some View {
        VStack(spacing: NoopMetrics.sectionGap) {
            header
            Spacer(minLength: 0)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                circle(model.pacer(at: ctx.date))
            }
            Spacer(minLength: 0)
            readings
            controls
        }
        .padding(NoopMetrics.screenPadding)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text(verbatim: BreathingL10n.text(model.exercise.title))
                .font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(partTitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            if let pace = model.sweepPace {
                Text("Pace \(String(format: "%.1f", pace)) breaths/min")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var partTitle: String {
        switch model.part {
        case .free:
            return String(localized: "Free breathing · \(clock(max(0, model.freeSeconds - model.partElapsed))) left")
        case .guided:
            return String(localized: "Exercise · \(clock(max(0, model.guidedSeconds - model.partElapsed))) left")
        case .recovery(let r):
            return String(localized: "Calm breathing · round \(r)")
        case .hold(let r):
            return String(localized: "Hold · round \(r)")
        case .done:
            return ""
        }
    }

    @ViewBuilder
    private func circle(_ p: BreathingSessionModel.Pacer?) -> some View {
        let fill = p?.fill ?? 0.5
        let size: CGFloat = 260
        ZStack {
            Circle()
                .stroke(StrandPalette.hairlineStrong, lineWidth: 2)
                .frame(width: size, height: size)
            Circle()
                .fill(StrandPalette.accent.opacity(0.28))
                .frame(width: size, height: size)
                .scaleEffect(reduceMotion ? 1 : 0.4 + 0.6 * fill)
            VStack(spacing: 6) {
                if let p {
                    Text(verbatim: phaseWord(p)).font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                    if case .hold = model.part {
                        Text(clock(model.partElapsed)).font(StrandFont.number(34)).foregroundStyle(StrandPalette.textPrimary)
                    } else {
                        Text("\(p.secondsLeft)").font(StrandFont.number(34)).foregroundStyle(StrandPalette.textSecondary)
                    }
                } else {
                    Text("Breathe normally").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                    Text(clock(model.partElapsed)).font(StrandFont.number(34)).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .frame(height: size)
        .accessibilityElement(children: .combine)
    }

    private func phaseWord(_ p: BreathingSessionModel.Pacer) -> String {
        if let label = p.label { return BreathingL10n.text(label) }
        switch p.phase {
        case .inhale: return String(localized: "Breathe in")
        case .exhale: return String(localized: "Breathe out")
        case .hold, .textOnly: return String(localized: "Hold")
        }
    }

    private var readings: some View {
        HStack(spacing: NoopMetrics.gap) {
            StatTile(label: "Heart rate", value: model.heartRate.map { "\($0)" } ?? "—", caption: "bpm")
            StatTile(label: "Breathing", value: model.breathsPerMin.map { String(format: "%.1f", $0) } ?? "—",
                     caption: String(localized: "/min"))
            StatTile(label: "Coherence", value: model.coherence.map { "\(Int($0.rounded()))" } ?? "—", caption: "/100")
        }
    }

    private var controls: some View {
        VStack(spacing: NoopMetrics.gap) {
            if case .hold = model.part {
                NoopButton("I'm breathing again", systemImage: "wind", kind: .primary, fullWidth: true) { model.endHold() }
            }
            if model.part == .free {
                NoopButton("Skip to the exercise", systemImage: "forward.fill", kind: .secondary, fullWidth: true) { model.skipFree() }
            }
            NoopButton("Stop", systemImage: "stop.fill", kind: .tertiary, fullWidth: true) { model.stop() }
            if let c = model.exercise.caution {
                Text(verbatim: BreathingL10n.text(c)).font(StrandFont.caption).foregroundStyle(StrandPalette.statusWarning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Summary

    private func summary(_ s: BreathingSessionModel.Summary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Session done").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: BreathingL10n.text(model.exercise.title)).font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                if s.free.seconds > 0 { partCard(String(localized: "Free breathing"), s.free) }
                partCard(String(localized: "Exercise"), s.guided)
                if let delta = heartRateChange(s) {
                    Text(verbatim: delta).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !s.holdsSeconds.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Breath holds").strandOverline()
                        Text(s.holdsSeconds.map(clock).joined(separator: " · "))
                            .font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                if let bpm = s.resonanceBpm {
                    Text(s.resonanceLocked
                         ? String(localized: "Your resonance pace: \(String(format: "%.1f", bpm)) breaths/min. \"Coherence at my pace\" now uses it.")
                         : String(localized: "No clear resonance pace this time (too few clean beats). Try again with the chest strap."))
                        .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let p = s.progression { progressionLine(p) }
                uploadLine
                NoopButton("Close", kind: .primary, fullWidth: true) { onClose() }
            }
            .padding(NoopMetrics.screenPadding)
        }
    }

    private func partCard(_ title: String, _ p: BreathingSessionModel.PartStats) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(verbatim: "\(title) · \(clock(p.seconds))").strandOverline()
            HStack(spacing: NoopMetrics.gap) {
                StatTile(label: "Avg HR", value: p.avgHR.map { "\(Int($0.rounded()))" } ?? "—", caption: "bpm")
                StatTile(label: "Breathing", value: p.avgBreathsPerMin.map { String(format: "%.1f", $0) } ?? "—",
                         caption: String(localized: "/min"))
            }
            HStack(spacing: NoopMetrics.gap) {
                StatTile(label: "HRV (RMSSD)", value: p.rmssd.map { "\(Int($0.rounded()))" } ?? "—", caption: "ms")
                StatTile(label: "Coherence", value: p.avgCoherence.map { "\(Int($0.rounded()))" } ?? "—", caption: "/100")
            }
        }
    }

    private func heartRateChange(_ s: BreathingSessionModel.Summary) -> String? {
        guard let a = s.free.avgHR, let b = s.guided.avgHR, s.free.seconds > 0 else { return nil }
        let diff = Int((b - a).rounded())
        return diff < 0
            ? String(localized: "Your heart rate dropped by \(-diff) bpm during the exercise.")
            : String(localized: "Your heart rate stayed within \(diff) bpm of free breathing.")
    }

    private func progressionLine(_ p: BreathingSessionModel.Progression) -> some View {
        let id = model.exercise.id
        let text: String
        if p.leveledUp {
            text = String(localized: "Level up: level \(p.after.level) of \(BreathingProgression.maxLevel(id)). The next session is harder.")
                + (id == BreathingScienceCatalog.respiratoryMuscleId
                   ? " " + String(localized: "With an inspiratory trainer, also raise its resistance one notch.") : "")
        } else if !p.completedFully {
            text = String(localized: "Stopped before the end: this session does not count toward the next level.")
        } else if p.after.level >= BreathingProgression.maxLevel(id) {
            text = String(localized: "Top level reached. Keep it up to hold your gains.")
        } else {
            let left = BreathingProgression.sessionsPerLevel(id) - p.after.completions
            text = String(localized: "\(left) more full sessions to reach level \(p.after.level + 1).")
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: p.leveledUp ? "arrow.up.circle.fill" : "chart.line.uptrend.xyaxis")
                .foregroundStyle(p.leveledUp ? StrandPalette.statusPositive : StrandPalette.accent)
            Text(verbatim: text).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var uploadLine: some View {
        switch model.upload {
        case .notConfigured:
            Text("Not sent: add your intervals.icu API key in Settings.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        case .sending:
            HStack(spacing: 8) {
                ProgressView()
                Text("Sending to intervals.icu…").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        case .sent:
            Label("Sent to intervals.icu", systemImage: "checkmark.circle.fill")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.statusPositive)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 6) {
                Text("Sending to intervals.icu failed (\(why)).")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.statusCritical)
                NoopButton("Try again", systemImage: "arrow.clockwise", kind: .secondary) { model.retryUpload() }
            }
        }
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
#endif
