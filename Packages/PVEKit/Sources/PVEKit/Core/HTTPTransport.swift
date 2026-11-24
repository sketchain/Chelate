import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Abstraction over the HTTP stack so the API client can be unit tested with fixtures.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession based transport. TLS trust decisions live in the session delegate (App layer);
/// when the delegate rejects a certificate it records the reason in `trust`, which is turned
/// into a `PVEError.certificate` here.
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let trust: TrustEvaluator?

    public init(session: URLSession, trust: TrustEvaluator?) {
        self.session = session
        self.trust = trust
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PVEError.network(.other("Non-HTTP response"))
            }
            return (data, http)
        } catch let error as PVEError {
            throw error
        } catch let error as URLError {
            if let failure = trust?.takeLastFailure() {
                throw PVEError.certificate(failure)
            }
            throw PVEError.from(urlError: error)
        } catch is CancellationError {
            throw PVEError.cancelled
        } catch {
            if let failure = trust?.takeLastFailure() {
                throw PVEError.certificate(failure)
            }
            throw PVEError.network(.other(String(describing: error)))
        }
    }
}
