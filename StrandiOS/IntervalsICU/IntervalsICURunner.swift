#if os(iOS)
import Foundation
import WhoopStore

@MainActor
public final class IntervalsICURunner: ObservableObject {
    public static let shared = IntervalsICURunner()

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastResult: String?
    /// The PUSH direction's own status, kept separate from `lastResult` (the pull/import status).
    /// They used to share one variable: a push failure's message could be silently overwritten by the
    /// next automatic import's success line (which runs right after it, every sync), so a user with a
    /// genuinely broken push had no way to see that from this screen. nil until the first push attempt
    /// (enabled or not) — see `pushLastNightIfEnabled`'s doc comment for why `.disabled` stays nil too.
    @Published public private(set) var lastPushResult: String?

    private var cachedStore: WhoopStore?

    private init() {}

    public func importRecent(days: Int = 30) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        guard let store = await store() else {
            lastResult = "local database unavailable"
            return
        }
        do {
            let count = try await IntervalsICUImporter.importRecent(days: days, store: store)
            lastResult = "\(count) séance(s) importée(s)"
        } catch {
            lastResult = "échec : \(error)"
        }
    }

    /// Push last night's computed summary to intervals.icu. No-ops when
    /// `IntervalsICUSettings.pushEnabled` is off, same safe-to-call-unconditionally shape as the
    /// self-hosted push's `runIfConfigured()`. Runs from an automatic post-offload hook, not a
    /// user-initiated action, so `.disabled` is deliberately NOT written to `lastPushResult` — most
    /// installs never turn this on, and writing a status every sync for a feature nobody enabled would
    /// make the Settings screen's status card look like it's reporting on something it isn't.
    public func pushLastNightIfEnabled() async {
        guard let store = await store() else { return }
        do {
            let outcome = try await IntervalsICUWellnessPush.pushLatestNight(store: store)
            switch outcome {
            case .pushed(let day): lastPushResult = "Envoyé pour le \(day)"
            case .disabled: break
            case .noApiKey: lastPushResult = "Clé API manquante"
            case .nothingToPush: lastPushResult = "Aucune nuit récente avec des données de sommeil à envoyer"
            }
        } catch {
            lastPushResult = "Échec : \(error)"
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
