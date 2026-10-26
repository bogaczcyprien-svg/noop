#if os(iOS)
import Foundation
import StrandAnalytics

/// Where the Breathing tab keeps finished sessions (fork addition): one small JSON file in Application
/// Support, local only. `BreathingHistory` holds the rules (what is kept, how much).
enum BreathingHistoryStore {
    private static var url: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("breathing-history.json")
    }

    static func load() -> [BreathingHistory.Entry] {
        guard let url, let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([BreathingHistory.Entry].self, from: data) else { return [] }
        return entries
    }

    static func append(_ entry: BreathingHistory.Entry) {
        guard let url else { return }
        let all = BreathingHistory.appending(entry, to: load())
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: url, options: .atomic) }
    }
}
#endif
