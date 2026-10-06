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

    /// Which wellness fields to send once the push itself is on. Keyed by field so a user who wants
    /// HRV/sleep on intervals.icu but not their weight (or vice versa) can say so, rather than it
    /// being all five fields or none. Every key defaults true: the push stayed off by default, but once
    /// a user opts in they almost certainly want everything NOOP can send, matching what intervals.icu
    /// itself shows per day (sleep, resting HR, HRV, weight, steps).
    public enum WellnessField: String, CaseIterable {
        case hrv, restingHR, sleep, weight, steps
        /// NOOP's own computed Charge (recovery, 0-100) — not a raw input like the others, the
        /// SCORE itself. Maps to intervals.icu's `readiness` field (the Wellness schema has no
        /// dedicated "recovery"/"charge" field; `readiness` is the closest fit for a single
        /// composite number). Added at explicit user request: pushing HRV/resting-HR alone lets
        /// intervals.icu compute ITS OWN readiness-like figure from raw inputs, which is not the
        /// same number as NOOP's Charge — this sends NOOP's own number instead.
        case charge
        fileprivate var key: String { "noop.intervalsicu.push.\(rawValue)" }
    }

    @Published public private(set) var athleteId: String
    @Published public private(set) var hasApiKey: Bool
    /// Opt-in, default OFF (fork addition): write last night's HRV/resting-HR/sleep summary to
    /// intervals.icu's wellness entry each morning once computed. Nothing is ever read back for
    /// this direction — matches NOOP's one-way-export convention.
    @Published public private(set) var pushEnabled: Bool
    @Published public private(set) var pushFields: Set<WellnessField>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.athleteId = defaults.string(forKey: athleteIdKey) ?? "0"
        self.pushEnabled = defaults.bool(forKey: pushEnabledKey)
        self.pushFields = Set(WellnessField.allCases.filter {
            defaults.object(forKey: $0.key) == nil || defaults.bool(forKey: $0.key)
        })
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

    public func setPushField(_ field: WellnessField, enabled: Bool) {
        if enabled { pushFields.insert(field) } else { pushFields.remove(field) }
        defaults.set(enabled, forKey: field.key)
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
