#if os(iOS)
import SwiftUI
import StrandDesign

/// Self-hosted push settings (docs/PUSH_PROTOCOL.md): a user-owned HTTP(S) endpoint that receives a
/// one-way, append-only/replace-window export of local data. Off by default; NOOP never reads
/// anything back from the configured destination.
struct SelfHostedPushSettingsView: View {
    @ObservedObject private var settings = SelfHostedPushSettings.shared
    @ObservedObject private var runner = PushRunner.shared

    @State private var endpointDraft: String = ""
    @State private var tokenDraft: String = ""
    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle, testing, success(streams: Int), failure(String)
    }

    var body: some View {
        ScreenScaffold(
            title: "Self-Hosted Push",
            subtitle: "One-way export to a server you own. Off until you configure and enable it below."
        ) {
            configCard
            statusCard
        }
        .onAppear {
            endpointDraft = settings.endpointRaw
        }
    }

    private var configCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text("Destination")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint URL").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    TextField("https://your-server/push/noop", text: $endpointDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(StrandFont.subhead)
                        .onSubmit { settings.setEndpoint(endpointDraft) }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Bearer token").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    SecureField(settings.hasToken ? "Token saved — enter to replace" : "Paste token", text: $tokenDraft)
                        .font(StrandFont.subhead)
                        .onSubmit {
                            guard !tokenDraft.isEmpty else { return }
                            settings.setToken(tokenDraft)
                            tokenDraft = ""
                        }
                }

                Toggle(isOn: Binding(
                    get: { settings.isEnabled },
                    set: { newValue in
                        settings.setEndpoint(endpointDraft)
                        settings.setEnabled(newValue)
                        PushBackgroundScheduler.schedule()
                    }
                )) {
                    Text("Enable self-hosted push").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)

                HStack(spacing: 12) {
                    Button {
                        settings.setEndpoint(endpointDraft)
                        Task { await runTest() }
                    } label: {
                        if testState == .testing {
                            ProgressView()
                        } else {
                            Text("Test connection")
                        }
                    }
                    .disabled(endpointDraft.isEmpty || (!settings.hasToken && tokenDraft.isEmpty) || testState == .testing)

                    Button("Push now") {
                        settings.setEndpoint(endpointDraft)
                        Task { await runner.runIfConfigured() }
                    }
                    .disabled(!settings.isEnabled || runner.isRunning)
                }
                .font(StrandFont.subhead)

                testStateView
            }
        }
    }

    @ViewBuilder
    private var testStateView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            EmptyView()
        case .success(let streams):
            Label("Connected — \(streams) stream\(streams == 1 ? "" : "s") accepted", systemImage: "checkmark.circle.fill")
                .font(StrandFont.caption)
                .foregroundStyle(.green)
        case .failure(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(StrandFont.caption)
                .foregroundStyle(.orange)
        }
    }

    private var statusCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last run").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                if let result = runner.lastResult {
                    Text("\(result.acceptedBatches) batch(es) accepted, \(result.acceptedRecords) record(s), \(result.rejectedBatches) rejected")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Nothing pushed yet.").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                if let error = runner.lastError {
                    Text(error).font(StrandFont.caption).foregroundStyle(.orange)
                }
                Text("NOOP never reads health data, commands, or settings back from this destination — see docs/PUSH_PROTOCOL.md.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runTest() async {
        testState = .testing
        switch await runner.testConnection() {
        case .success(let caps):
            testState = .success(streams: caps.appendTables.count + caps.mutableTables.count)
        case .failure(let reason):
            testState = .failure(reason)
        }
    }
}
#endif
