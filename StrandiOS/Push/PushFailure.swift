import Foundation

public enum PushFailureCode: String, Sendable {
    case dnsLookup, tlsCertificate, tlsHandshake, networkTimeout, connectionRefused
    case networkUnreachable, connectionReset, networkIO
    case httpAuth, httpNotFound, httpTimeout, httpTooLarge, httpMediaType
    case httpProtocolRejected, httpRateLimit, httpServer, httpClient
    case capabilitiesInvalid, ackInvalid, localData, localDatabase
}

public struct PushFailure: Sendable {
    public let code: PushFailureCode
    public let httpStatus: Int?
    public let receiverCode: String?

    public init(code: PushFailureCode, httpStatus: Int? = nil, receiverCode: String? = nil) {
        self.code = code
        self.httpStatus = httpStatus
        self.receiverCode = receiverCode
    }

    public var safeCode: String {
        var s = code.rawValue
        if let httpStatus { s += ":http_\(httpStatus)" }
        if let receiverCode { s += ":receiver_\(receiverCode)" }
        return s
    }

    public var retryable: Bool {
        switch code {
        case .dnsLookup, .tlsHandshake, .networkTimeout, .connectionRefused, .networkUnreachable,
             .connectionReset, .networkIO, .httpTimeout, .httpRateLimit, .httpServer, .localDatabase:
            return true
        default:
            return false
        }
    }

    public static func http(status: Int, receiverCode: String? = nil) -> PushFailure {
        let code: PushFailureCode
        switch status {
        case 401, 403: code = .httpAuth
        case 404: code = .httpNotFound
        case 408: code = .httpTimeout
        case 413: code = .httpTooLarge
        case 415: code = .httpMediaType
        case 400, 409, 422: code = .httpProtocolRejected
        case 429: code = .httpRateLimit
        case 500...599: code = .httpServer
        default: code = .httpClient
        }
        return PushFailure(code: code, httpStatus: status, receiverCode: receiverCode)
    }
}

public struct PushTransportException: Error {
    public let failure: PushFailure
    public init(_ failure: PushFailure) { self.failure = failure }
}

/// Carries only a stable category; the platform cause is never rendered or persisted.
func classifyPushTransportFailure(_ error: Error) -> PushFailure {
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return PushFailure(code: .networkIO) }
    let code: PushFailureCode
    switch nsError.code {
    case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
        code = .dnsLookup
    case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
         NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
         NSURLErrorClientCertificateRejected:
        code = .tlsCertificate
    case NSURLErrorSecureConnectionFailed:
        code = .tlsHandshake
    case NSURLErrorTimedOut:
        code = .networkTimeout
    case NSURLErrorCannotConnectToHost:
        code = .connectionRefused
    case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorInternationalRoamingOff:
        code = .networkUnreachable
    default:
        code = .networkIO
    }
    return PushFailure(code: code)
}
