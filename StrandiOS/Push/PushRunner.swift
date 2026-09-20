#if os(iOS)
import Foundation
import WhoopStore

public struct PushSimpleError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Assembles the push feature (settings → snapshot source → transport → coordinator) and exposes the
/// three trigger points the protocol doc calls for: after a BLE offload, at app-launch catch-up, and
/// an explicit "Push now".
@MainActor
public final class PushRunner: ObservableObject {
    public static let shared = PushRunner()

    @Published public private(set) var lastResult: PushRunResult?
    @Published public private(set) var lastError: String?
    @Published public private(set) var isRunning = false

    private var cachedStore: WhoopStore?
    private let progress = UserDefaultsPushProgressStore()

    private init() {}

    /// Best-effort, non-throwing: a push failure must never affect strap sync, local writes, or UI.
    public func runIfConfigured() async {
        guard SelfHostedPushSettings.shared.isEnabled,
              let endpoint = SelfHostedPushSettings.shared.validatedEndpoint(),
              let token = SelfHostedPushSettings.shared.token(), !token.isEmpty
        else { return }
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        guard let store = await store() else {
            lastError = "local database unavailable"
            return
        }
        let source = GRDBPushSnapshotSource(store: store)
        let transport = PushHttpTransport(endpoint: endpoint, bearerToken: token)
        let coordinator = PushCoordinator(source: source, transport: transport, progress: progress, sourceId: SelfHostedPushSettings.shared.sourceId)

        let capResult = await transport.capabilities()
        let capabilities: PushCapabilities
        switch capResult {
        case .available(let c):
            capabilities = PushCapabilities(
                appendTables: c.appendTables.intersection(GRDBPushSnapshotSource.supportedAppendTables),
                mutableTables: c.mutableTables.intersection(GRDBPushSnapshotSource.supportedMutableTables),
                protocolVersion: c.protocolVersion, receiverStateId: c.receiverStateId
            )
        case .rejected(let reason, _, _):
            lastError = reason
            return
        }

        let result = await coordinator.pushKnownDevices(capabilities: capabilities)
        lastResult = result
        lastError = result.failure?.safeCode
    }

    /// "Test connection" — capability discovery only, no batch, no database read (matches the
    /// protocol doc: this GET alone never opens the health database).
    public func testConnection() async -> Result<PushCapabilities, PushSimpleError> {
        guard let endpoint = SelfHostedPushSettings.shared.validatedEndpoint() else {
            return .failure(PushSimpleError("invalid endpoint"))
        }
        guard let token = SelfHostedPushSettings.shared.token(), !token.isEmpty else {
            return .failure(PushSimpleError("no token configured"))
        }
        let transport = PushHttpTransport(endpoint: endpoint, bearerToken: token)
        switch await transport.capabilities() {
        case .available(let c): return .success(c)
        case .rejected(let reason, _, _): return .failure(PushSimpleError(reason))
        }
    }

    private func store() async -> WhoopStore? {
        if let cachedStore { return cachedStore }
        guard let path = try? StorePaths.defaultDatabasePath(),
              let opened = try? await WhoopStore(path: path)
        else { return nil }
        cachedStore = opened
        return opened
    }
}
#endif
