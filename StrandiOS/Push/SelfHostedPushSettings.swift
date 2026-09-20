import Foundation
import Security

/// Endpoint/enabled state in `UserDefaults` (not sensitive); the bearer token in Keychain.
@MainActor
public final class SelfHostedPushSettings: ObservableObject {
    public static let shared = SelfHostedPushSettings()

    private let defaults: UserDefaults
    private let endpointKey = "noop.push.endpoint"
    private let enabledKey = "noop.push.enabled"
    private let keychainService = "com.noopapp.noop.push"
    private let keychainAccount = "bearerToken"

    @Published public private(set) var endpointRaw: String
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var hasToken: Bool
    public let sourceId: String

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.endpointRaw = defaults.string(forKey: endpointKey) ?? ""
        self.isEnabled = defaults.bool(forKey: enabledKey)
        self.hasToken = false
        let sourceIdKey = "noop.push.sourceId"
        if let existing = defaults.string(forKey: sourceIdKey) {
            self.sourceId = existing
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: sourceIdKey)
            self.sourceId = generated
        }
        self.hasToken = readToken() != nil
    }

    public func setEndpoint(_ raw: String) {
        endpointRaw = raw
        defaults.set(raw, forKey: endpointKey)
        Task { await UserDefaultsPushProgressStore().resetAll() }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: enabledKey)
    }

    public func setToken(_ token: String) {
        writeToken(token)
        hasToken = !token.isEmpty
        Task { await UserDefaultsPushProgressStore().resetAll() }
    }

    public func token() -> String? { readToken() }

    public func validatedEndpoint() -> PushEndpointPolicy.ValidEndpoint? {
        guard case .valid(let endpoint) = PushEndpointPolicy.validate(endpointRaw) else { return nil }
        return endpoint
    }

    // MARK: - Keychain

    private func readToken() -> String? {
        var query: [CFString: Any] = [
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
        _ = query // silence unused-var warnings on some SDKs
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeToken(_ token: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData] = Data(token.utf8)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
