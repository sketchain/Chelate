import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Typed access to `/api2/json` of one server.
public final class PVEClient: Sendable {
    public let endpoint: ServerEndpoint
    public let auth: AuthSession
    private let transport: any HTTPTransport

    public init(endpoint: ServerEndpoint, auth: AuthSession, transport: any HTTPTransport) {
        self.endpoint = endpoint
        self.auth = auth
        self.transport = transport
    }

    /// Performs a request and decodes the `data` member. On a 401 with ticket auth the ticket is
    /// dropped and the request retried once (renewal / re-login happens transparently).
    public func request<T: Decodable & Sendable>(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        form: [(String, String)]? = nil,
        as type: T.Type = T.self
    ) async throws -> T {
        do {
            return try await perform(method, path, query: query, form: form, as: type)
        } catch PVEError.unauthorized(let message) {
            guard !auth.usesAPIToken else { throw PVEError.unauthorized(message: message) }
            await auth.invalidateTicket()
            return try await perform(method, path, query: query, form: form, as: type)
        }
    }

    private func perform<T: Decodable & Sendable>(
        _ method: HTTPMethod,
        _ path: String,
        query: [URLQueryItem],
        form: [(String, String)]?,
        as type: T.Type
    ) async throws -> T {
        let headers = try await auth.headers(isWrite: method.isWrite)
        let request = RequestFactory.make(
            endpoint: endpoint,
            method: method,
            path: path,
            query: query,
            form: form,
            headers: headers
        )
        try Task.checkCancellation()
        let (data, response) = try await transport.send(request)
        return try ResponseDecoding.decode(type, data: data, response: response)
    }

    /// A WebSocket upgrade request for `vncwebsocket`, authenticated like REST calls.
    public func webSocketRequest(path: String, port: Int, vncTicket: String) async throws -> URLRequest {
        let url = endpoint.webSocketURL(path: path, query: [
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "vncticket", value: vncTicket),
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        for (name, value) in try await auth.webSocketHeaders() {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}
