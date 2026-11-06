import SwiftUI
import StrandDesign

/// Fork: the SpO2 screen's table of today's all-day readings from the Garmin server, newest first.
/// Draws nothing when the server is not connected or has no reading yet today.
struct GarminSpO2DayTable: View {
    @ObservedObject private var server = GarminServerSync.shared
    @State private var readings: [(ts: Int, pct: Int)] = []

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    var body: some View {
        Group {
            if !readings.isEmpty {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                        Text("Today's readings").strandOverline()
                        HStack(spacing: 12) {
                            Text("Time").frame(maxWidth: .infinity, alignment: .leading)
                            Text("SpO₂").frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        VStack(spacing: 0) {
                            ForEach(Array(readings.reversed().enumerated()), id: \.offset) { idx, r in
                                HStack(spacing: 12) {
                                    Text(Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(r.ts))))
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(r.pct) %")
                                        .font(StrandFont.number(15))
                                        .foregroundStyle(StrandPalette.textPrimary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .padding(.vertical, 8)
                                if idx < readings.count - 1 { Divider().opacity(0.3) }
                            }
                        }
                    }
                }
            }
        }
        .task(id: server.lastRunAt) {
            guard server.isConnected else { readings = []; return }
            readings = await server.spo2Readings()
        }
    }
}
