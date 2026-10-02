import Foundation
import Security

/// Athlete ID in UserDefaults (not sensitive); the API key in Keychain.
@MainActor
public final class IntervalsICUSettings: ObservableObject {
    public static let shared = IntervalsICUSettings()

    private let defaults: UserDefaults
    private let athleteIdKey = "noop.intervalsicu.athleteId"
    private let pushEnabledKey = "noop.intervalsicu.pushEnabled"
    private let keychainService = "com.noopapp.noop.intervalsicu"
    private let keychainAccount = "apiKey"

    @Published public private(set) var athleteId: String
    @Published public private(set) var hasApiKey: Bool
    /// Opt-in, default OFF (fork addition): write last night's HRV/resting-HR/sleep summary to
    /// intervals.icu's wellness entry each morning once computed. Nothing is ever read back for
    /// this direction — matches NOOP's one-way-export convention.
    @Published public private(set) var pushEnabled: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.athleteId = defaults.string(forKey: athleteIdKey) ?? "0"
        self.pushEnabled = defaults.bool(forKey: pushEnabledKey)
        self.hasApiKey = false
        self.hasApiKey = readApiKey() != nil
    }

    public func setAthleteId(_ id: String) {
        athleteId = id
        defaults.set(id, forKey: athleteIdKey)
    }

    public func setPushEnabled(_ enabled: Bool) {
        pushEnabled = enabled
        defaults.set(enabled, forKey: pushEnabledKey)
    }

    public func setApiKey(_ key: String) {
        writeApiKey(key)
        hasApiKey = !key.isEmpty
    }

    public func apiKey() -> String? { readApiKey() }

    // MARK: - Keychain

    private func readApiKey() -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = withUnsafeMutablePointer(to: &result) { ptr in
            SecItemCopyMatching(query as CFDictionary, ptr)
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeApiKey(_ key: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData] = Data(key.utf8)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
