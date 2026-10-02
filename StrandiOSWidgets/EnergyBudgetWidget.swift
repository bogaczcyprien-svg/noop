import WidgetKit
import SwiftUI
import StrandDesign

/// "Energy budget" lock-screen gauge — fork addition, in the spirit of Garmin's Body Battery: a
/// depleting-through-the-day visual, built from data NOOP already tracks rather than a new model.
/// `remaining = 100 - Effort` (Effort is NOOP's 0-100 cumulative-strain axis, so as the day's load
/// accumulates this empties, same concept, no new engine). Reuses `NOOPProvider`/`NOOPEntry`
/// (`NOOPWidget.swift`) verbatim — same `WidgetSnapshot` App Group source, same ~15-minute refresh —
/// so this is a new PRESENTATION of existing data, not a new data pipeline.
///
/// A true always-on Live Activity (continuously updating without the app open) would need an
/// ActivityKit push-update channel, which means a server — out of scope for an offline, no-server app.
/// This accessory widget is the realistic equivalent: add it to the Lock Screen and it refreshes
/// itself through the day same as the existing Charge gauge already does.
struct EnergyBudgetWidgetView: View {
    let entry: NOOPEntry

    private var remaining: Int? {
        entry.snapshot.effort.map { max(0, 100 - $0) }
    }

    private var tint: Color {
        guard let remaining else { return StrandPalette.textTertiary }
        switch remaining {
        case 60...: return StrandPalette.statusPositive
        case 30..<60: return StrandPalette.statusWarning
        default: return StrandPalette.statusCritical
        }
    }

    var body: some View {
        Gauge(value: Double(remaining ?? 0), in: 0...100) {
            Image(systemName: "bolt.fill")
        } currentValueLabel: {
            Text(remaining.map { "\($0)" } ?? "–")
        }
        .gaugeStyle(.accessoryCircular)
        .tint(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Energy budget remaining today"))
        .accessibilityValue(Text(remaining.map { "\($0) out of 100" } ?? "unavailable"))
    }
}

struct EnergyBudgetWidget: Widget {
    let kind = "EnergyBudgetWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            EnergyBudgetWidgetView(entry: entry)
        }
        .configurationDisplayName("Energy Budget")
        .description("How much of today's energy budget is left, from 100 minus today's Effort.")
        .supportedFamilies([.accessoryCircular])
    }
}
