import Foundation

/// Minimal HTTP adapter: no redirects, bounded acknowledgement/error reads.
///
/// Unlike the Android transport, this sends the decoded NDJSON entity as identity encoding (no
/// gzip) — protocol 1.0 explicitly allows this for non-Android senders, and it avoids needing a
/// from-scratch gzip/CRC32 implementation for what is, on a local network, a marginal bandwidth
/// saving.
public final class PushHttpTransport: PushTransport {
    static let acceptVersionHeader = "NOOP-Push-Accept-Version"

    private let endpoint: PushEndpointPolicy.ValidEndpoint
    private let bearerToken: String
    private let session: URLSession

    public init(endpoint: PushEndpointPolicy.ValidEndpoint, bearerToken: String, session: URLSession = PushHttpTransport.defaultSession()) {
        self.endpoint = endpoint
        self.bearerToken = bearerToken
        self.session = session
    }

    public static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    public func capabilities() async -> PushCapabilitiesResult {
        guard let url = URL(string: endpoint.url) else {
            return .rejected(reason: PushFailureCode.networkIO.rawValue, retryable: false, failure: PushFailure(code: .networkIO))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(PushProtocol.version, forHTTPHeaderField: Self.acceptVersionHeader)

        let response: PushTransportResponse
        do {
            response = try await execute(request)
        } catch let e as PushTransportException {
            return .rejected(reason: e.failure.safeCode, retryable: e.failure.retryable, failure: e.failure)
        } catch {
            let f = PushFailure(code: .networkIO)
            return .rejected(reason: f.safeCode, retryable: f.retryable, failure: f)
        }
        guard (200...299).contains(response.statusCode) else {
            let f = PushFailure.http(status: response.statusCode, receiverCode: parseErrorCode(response.body))
            return .rejected(reason: f.safeCode, retryable: f.retryable, failure: f)
        }
        do {
            return .available(try PushCapabilities.parse(response.body))
        } catch {
            let f = PushFailure(code: .capabilitiesInvalid)
            return .rejected(reason: f.safeCode, retryable: f.retryable, failure: f)
        }
    }

    public func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        guard let url = URL(string: endpoint.url) else { throw PushTransportException(PushFailure(code: .networkIO)) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-ndjson; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = batch.body
        return try await execute(request)
    }

    private func execute(_ request: URLRequest) async throws -> PushTransportResponse {
        do {
            let (data, urlResponse) = try await session.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse else {
                throw PushTransportException(PushFailure(code: .networkIO))
            }
            let bounded = data.count > PushProtocol.maxAckBytes ? data.prefix(PushProtocol.maxAckBytes + 1) : data
            return PushTransportResponse(statusCode: http.statusCode, body: Data(bounded))
        } catch let e as PushTransportException {
            throw e
        } catch {
            throw PushTransportException(classifyPushTransportFailure(error))
        }
    }

    private func parseErrorCode(_ body: Data) -> String? {
        guard body.count <= PushProtocol.maxAckBytes,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              obj["type"] as? String == "error",
              obj["protocolVersion"] as? String == PushProtocol.version,
              let code = obj["code"] as? String,
              code.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil
        else { return nil }
        return code
    }

    /// Never follow redirects — a redirected destination is not the one the user configured.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }
}
