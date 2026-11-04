import Foundation
import Security

/// HTTP client for the user's own Garmin collection server (FastAPI behind a Cloudflare tunnel). The
/// tunnel hostname changes whenever the server restarts, so the current base URL is published as plain
/// text in a Gist and resolved on every sync; the last good URL is kept as a fallback.
///
/// Auth is the server's own app account (NOT the Garmin credentials): `POST /auth/login` returns a
/// long-lived JWT, sent as `Authorization: Bearer <token>`. The token lives in the Keychain.
struct GarminServerClient {
    static let gistURL = URL(string: "https://gist.githubusercontent.com/bogaczcyprien-svg/6caf2b6e6f88ad1fa5f86c7b158c7a01/raw/gistfile1.txt")!
    private static let lastBaseKey = "garminServer.lastBaseURL"

    enum Failure: LocalizedError {
        case noServer, unauthorized, http(Int), badResponse
        var errorDescription: String? {
            switch self {
            case .noServer: return String(localized: "The Garmin server can't be reached right now.")
            case .unauthorized: return String(localized: "Wrong email or password, or the session expired. Sign in again.")
            case .http(let c): return String(localized: "The Garmin server answered with an error (\(c)).")
            case .badResponse: return String(localized: "The Garmin server sent an unexpected answer.")
            }
        }
    }

    let base: URL
    var token: String?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 90   // per-request timeouts are set on each URLRequest
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    /// Current tunnel URL from the Gist (cache-busted), falling back to the last one that worked.
    static func resolveBase() async throws -> URL {
        var req = URLRequest(url: gistURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let (data, resp) = try? await session.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: text), url.scheme?.hasPrefix("http") == true {
            UserDefaults.standard.set(url.absoluteString, forKey: lastBaseKey)
            return url
        }
        if let s = UserDefaults.standard.string(forKey: lastBaseKey), let url = URL(string: s) { return url }
        throw Failure.noServer
    }

    func login(email: String, password: String) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("auth/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let obj = try await send(req)
        guard let token = (obj as? [String: Any])?["token"] as? String, !token.isEmpty else { throw Failure.badResponse }
        return token
    }

    /// GET a JSON endpoint. Returns the decoded object (dictionary or array).
    func get(_ path: String, _ query: [String: String] = [:], timeout: TimeInterval = 30) async throws -> Any {
        var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return try await send(URLRequest(url: comps.url!, timeoutInterval: timeout))
    }

    /// Fire-and-forget `POST /sync-now` (non-blocking server side; it returns at once).
    func requestServerSync() async {
        var req = URLRequest(url: base.appendingPathComponent("sync-now"))
        req.httpMethod = "POST"
        _ = try? await send(req)
    }

    private func send(_ request: URLRequest) async throws -> Any {
        var req = request
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await Self.session.data(for: req) } catch { throw Failure.noServer }
        guard let http = resp as? HTTPURLResponse else { throw Failure.badResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw Failure.unauthorized
        case 502, 503, 504, 530: throw Failure.noServer   // tunnel up, origin down
        default: throw Failure.http(http.statusCode)
        }
        if data.isEmpty { return [String: Any]() }
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw Failure.badResponse }
        return obj
    }
}

/// Keychain storage for the server JWT and the account email (shown on the card). Same shape as
/// `OuraTokenStore`: one generic-password item, this-device-only.
enum GarminServerTokenStore {
    private static let service = "com.noop.garmin-server"
    private static let account = "jwt"
    private static let emailKey = "garminServer.email"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    @discardableResult
    static func save(token: String, email: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = Data(token.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        UserDefaults.standard.set(email, forKey: emailKey)
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var email: String? { UserDefaults.standard.string(forKey: emailKey) }

    static func clear() {
        SecItemDelete(baseQuery as CFDictionary)
        UserDefaults.standard.removeObject(forKey: emailKey)
    }
}
