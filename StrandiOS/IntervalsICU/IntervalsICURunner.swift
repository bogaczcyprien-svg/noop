#if os(iOS)
import Foundation
import WhoopStore

@MainActor
public final class IntervalsICURunner: ObservableObject {
    public static let shared = IntervalsICURunner()

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastResult: String?

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
