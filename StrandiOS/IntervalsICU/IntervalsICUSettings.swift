import Foundation
import Security

/// Athlete ID in UserDefaults (not sensitive); the API key in Keychain.
@MainActor
public final class IntervalsICUSettings: ObservableObject {
    public static let shared = IntervalsICUSettings()

    private let defaults: UserDefaults
    private let athleteIdKey = "noop.intervalsicu.athleteId"
    private let keychainService = "com.noopapp.noop.intervalsicu"
    private let keychainAccount = "apiKey"

    @Published public private(set) var athleteId: String
    @Published public private(set) var hasApiKey: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.athleteId = defaults.string(forKey: athleteIdKey) ?? "0"
        self.hasApiKey = false
        self.hasApiKey = readApiKey() != nil
    }

    public func setAthleteId(_ id: String) {
        athleteId = id
        defaults.set(id, forKey: athleteIdKey)
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
