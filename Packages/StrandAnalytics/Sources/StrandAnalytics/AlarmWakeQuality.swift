import Foundation

// AlarmWakeQuality.swift — INSTRUMENTATION ONLY (fork addition, not upstream).
//
// NOOP's smart alarm fires the strap buzz at one FIXED clock time (`behavior.smartAlarmMinutes`); it
// does not scan live sleep stage and pick a moment within a window the way some wearables' "light
// sleep wake" does. Building that live-timing version would mean the app staying connected and
// monitoring stage in real time near the window, then sending a buzz command at a moment the engine
// decides — a new BLE-interactive behavior this fork cannot validate on real hardware tonight.
//
// So this lands the SAFE increment instead, matching the project's own stated discipline for a
// physiological-signal-derived feature with no validation yet (see AGENTS.md's "Deriving a
// physiological signal..." rule): report, after the fact, what stage the ALREADY-FIXED alarm time
// landed in — instrumentation a caller can surface, never a change to when or whether the strap buzzes.
public enum AlarmWakeQuality {
    public enum Verdict: String, Equatable, Sendable {
        case light, deep, rem, wake, unknown
    }

    /// The sleep stage active at `alarmMinutesSinceMidnight` LOCAL clock time on the morning a session
    /// `[_, sessionEndTs]` ended, read from its already-computed stage segments. nil when the alarm
    /// instant doesn't fall inside any segment (the alarm wasn't during this sleep at all, or the
    /// session carries no segments).
    public static func stageAtAlarm(segments: [StageSegment], sessionEndTs: Int,
                                    alarmMinutesSinceMidnight: Int, tzOffsetSeconds: Int) -> Verdict? {
        let localEnd = sessionEndTs + tzOffsetSeconds
        let localDayStart = (localEnd / 86_400) * 86_400
        let alarmLocal = localDayStart + alarmMinutesSinceMidnight * 60
        let alarmUtc = alarmLocal - tzOffsetSeconds
        guard let seg = segments.first(where: { alarmUtc >= $0.start && alarmUtc < $0.end }) else { return nil }
        return Verdict(rawValue: seg.stage) ?? .unknown
    }
}
