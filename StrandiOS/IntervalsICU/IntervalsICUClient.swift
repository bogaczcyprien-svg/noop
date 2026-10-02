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

/// One named stream from the activity streams endpoint — `type` is e.g. "time"/"heartrate", `data`
/// the per-sample values aligned across every stream requested together (nulls where a sample is
/// missing, e.g. a GPS dropout). Fork addition.
public struct IntervalsICUStream: Decodable {
    public let type: String
    public let data: [Double?]
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

    /// Fetches named per-sample streams for one activity (e.g. `["time", "heartrate"]`) — real
    /// recorded data, not the base `activities(...)` call's single ride-average. "time" is seconds
    /// elapsed since the activity started (NOT always 1s apart — always request it alongside any
    /// other stream to know each sample's actual offset) per intervals.icu's own stream docs. Fork
    /// addition, used to backfill a truer HR trace than the flat-average fallback.
    public func streams(activityId: String, types: [String]) async throws -> [IntervalsICUStream] {
        var components = URLComponents(string: "https://intervals.icu/api/v1/activity/\(activityId)/streams.json")
        components?.queryItems = [URLQueryItem(name: "types", value: types.joined(separator: ","))]
        guard let url = components?.url else { throw IntervalsICUError.invalidURL }

        var request = URLRequest(url: url)
        let credentials = Data("API_KEY:\(apiKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IntervalsICUError.http(0) }
        guard (200...299).contains(http.statusCode) else { throw IntervalsICUError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode([IntervalsICUStream].self, from: data)
        } catch {
            throw IntervalsICUError.decoding
        }
    }

    /// Writes one night's already-computed summary to intervals.icu's wellness entry for `date`
    /// (merges into whatever's already there for that day — any field left nil here is untouched).
    /// Fork addition, the reverse direction of `activities(oldest:newest:)`: NOOP never reads this
    /// back, matching the one-way-export convention the self-hosted push client already follows.
    public func putWellness(date: String, hrv: Double?, restingHR: Int?,
                            sleepSecs: Int?, sleepScore: Int?) async throws {
        guard let url = URL(string: "https://intervals.icu/api/v1/athlete/\(athleteId)/wellness/\(date)")
        else { throw IntervalsICUError.invalidURL }

        var body: [String: Any] = [:]
        if let hrv { body["hrv"] = hrv }
        if let restingHR { body["restingHR"] = restingHR }
        if let sleepSecs { body["sleepSecs"] = sleepSecs }
        if let sleepScore { body["sleepScore"] = sleepScore }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let credentials = Data("API_KEY:\(apiKey)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw IntervalsICUError.http(0) }
        guard (200...299).contains(http.statusCode) else { throw IntervalsICUError.http(http.statusCode) }
    }

    public enum TestConnectionResult {
        case success(Int)
        case failure(String)
    }

    /// Cheap credential check: fetches a single day of activities.
    public func testConnection() async -> TestConnectionResult {
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
