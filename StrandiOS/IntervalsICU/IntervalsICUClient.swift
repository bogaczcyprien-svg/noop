import Foundation

/// Minimal client for the intervals.icu public API (https://intervals.icu/api/v1) — API-key auth,
/// read-only. Docs: https://forum.intervals.icu/t/api-access-to-intervals-icu/609
public struct IntervalsICUActivity: Decodable {
    let id: String
    let name: String?
    let type: String?
    let start_date_local: String?
    let moving_time: Int?
    let elapsed_time: Int?
    let distance: Double?
    let calories: Double?
    let average_heartrate: Double?
    let max_heartrate: Double?
}

public enum IntervalsICUError: Error {
    case invalidURL
    case http(Int)
    case decoding
}

public struct IntervalsICUClient {
    private let athleteId: String
    private let apiKey: String
    private let session: URLSession

    public init(athleteId: String, apiKey: String, session: URLSession = .shared) {
        self.athleteId = athleteId.isEmpty ? "0" : athleteId
        self.apiKey = apiKey
        self.session = session
    }

    /// Fetches activities with a start date in [oldest, newest] (local calendar days, inclusive).
    public func activities(oldest: String, newest: String) async throws -> [IntervalsICUActivity] {
        var components = URLComponents(string: "https://intervals.icu/api/v1/athlete/\(athleteId)/activities")
        components?.queryItems = [
            URLQueryItem(name: "oldest", value: oldest),
            URLQueryItem(name: "newest", value: newest),
        ]
        guard let url = components?.url else { throw IntervalsICUError.invalidURL }

        var request = URLRequest(url: url)
        let credentials = Data("API_KEY:\(apiKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IntervalsICUError.http(0) }
        guard (200...299).contains(http.statusCode) else { throw IntervalsICUError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode([IntervalsICUActivity].self, from: data)
        } catch {
            throw IntervalsICUError.decoding
        }
    }

    /// Cheap credential check: fetches a single day of activities.
    public func testConnection() async -> Result<Int, String> {
        let today = PushDayFormat.formatter.string(from: Date())
        do {
            let acts = try await activities(oldest: today, newest: today)
            return .success(acts.count)
        } catch IntervalsICUError.http(let code) {
            return .failure("HTTP \(code)")
        } catch {
            return .failure("\(error)")
        }
    }
}
