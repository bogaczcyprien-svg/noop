import Foundation

/// Security boundary for the user-supplied destination. Validation happens before DNS or HTTP.
/// Port of the Android `PushEndpointPolicy.kt`.
public enum PushEndpointPolicy {
    public struct ValidEndpoint: Equatable {
        public let url: String
        public let host: String
    }

    public enum Problem {
        case malformedURL, missingScheme, unsupportedScheme, userInfoNotAllowed, fragmentNotAllowed
        case missingHost, invalidHost, invalidPort, httpRequiresLocalAddress
    }

    public enum Result {
        case valid(ValidEndpoint)
        case invalid(Problem)
    }

    public static func validate(_ raw: String) -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed) else { return .invalid(.malformedURL) }
        guard let scheme = components.scheme?.lowercased() else { return .invalid(.missingScheme) }
        guard scheme == "http" || scheme == "https" else { return .invalid(.unsupportedScheme) }
        if components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            return .invalid(.userInfoNotAllowed)
        }
        if components.fragment != nil { return .invalid(.fragmentNotAllowed) }
        guard var rawHost = components.host?.lowercased() else { return .invalid(.missingHost) }
        if rawHost.hasPrefix("["), rawHost.hasSuffix("]") {
            rawHost = String(rawHost.dropFirst().dropLast())
        }
        guard !rawHost.isEmpty else { return .invalid(.invalidHost) }
        let asciiHost = rawHost
        if let port = components.port, !(0...65535).contains(port) { return .invalid(.invalidPort) }

        let literal = parseLiteralAddress(asciiHost)
        let literalAllowed = literal.map(isLocalAddress) ?? false
        if scheme == "http" && !literalAllowed { return .invalid(.httpRequiresLocalAddress) }

        let port = components.port ?? (scheme == "https" ? 443 : 80)
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        let authorityHost = asciiHost.contains(":") ? "[\(asciiHost)]" : asciiHost
        let authority = authorityHost + (defaultPort ? "" : ":\(port)")
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        var normalized = "\(scheme)://\(authority)\(path)"
        if let query = components.percentEncodedQuery { normalized += "?\(query)" }
        return .valid(ValidEndpoint(url: normalized, host: asciiHost))
    }

    /// RFC 1918 / link-local / loopback / ULA — private address space only. Never used to DNS-resolve
    /// a hostname; only literal IP addresses are checked.
    static func isLocalAddress(_ address: LiteralAddress) -> Bool {
        switch address {
        case .v4(let a, let b, _, _):
            return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254)
        case .v6(let bytes):
            if bytes.allSatisfy({ $0 == 0 }) { return false }
            let loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            let linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            let ula = (bytes[0] & 0xfe) == 0xfc
            return loopback || linkLocal || ula
        }
    }

    enum LiteralAddress {
        case v4(UInt8, UInt8, UInt8, UInt8)
        case v6([UInt8])
    }

    private static func parseLiteralAddress(_ host: String) -> LiteralAddress? {
        if host == "localhost" { return .v4(127, 0, 0, 1) }
        let v4Parts = host.split(separator: ".")
        if v4Parts.count == 4, v4Parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            let bytes = v4Parts.compactMap { UInt8($0) }
            guard bytes.count == 4 else { return nil }
            return .v4(bytes[0], bytes[1], bytes[2], bytes[3])
        }
        if host.contains(":") {
            var addr = in6_addr()
            let result = host.withCString { cstr in inet_pton(AF_INET6, cstr, &addr) }
            guard result == 1 else { return nil }
            let bytes = withUnsafeBytes(of: &addr) { Array($0) }
            return .v6(bytes)
        }
        return nil
    }
}
