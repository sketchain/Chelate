import Foundation

/// Coarse network failure classes, so the UI can show a meaningful message.
public enum NetworkFailure: Sendable, Hashable {
    case offline
    case timedOut
    case cannotFindHost
    case cannotConnect
    case connectionLost
    case localNetworkDenied
    case tls(String)
    case other(String)
}

/// Problems with the server certificate. Never silently ignored.
public enum CertificateTrustFailure: Sendable, Hashable, Error {
    /// The system does not trust the certificate and nothing is pinned yet: ask the user.
    case untrusted(CertificateInfo)
    /// A fingerprint is pinned for this server but the server presented a different one.
    case fingerprintMismatch(expected: CertificateFingerprint, presented: CertificateInfo)
}

public enum PVEError: Error, Sendable, Hashable {
    case network(NetworkFailure)
    case certificate(CertificateTrustFailure)
    /// 401: credentials or ticket rejected.
    case unauthorized(message: String?)
    /// 403: the authenticated user lacks a privilege. Not a malfunction.
    case forbidden(message: String?)
    case notFound(message: String?)
    /// Other HTTP errors (4xx/5xx/595/596...).
    case http(status: Int, message: String?)
    case decoding(String)
    case invalidEndpoint
    /// A password (or new login) is needed; no remembered password is available.
    case loginRequired
    /// The account requires a second factor but only unsupported ones (WebAuthn/U2F) exist.
    case tfaUnsupported
    /// The user dismissed the second-factor prompt.
    case tfaCancelled
    /// The console endpoints rejected the current auth method.
    case consoleUnavailable(reason: String)
    case cancelled

    public var isForbidden: Bool {
        if case .forbidden = self { return true }
        return false
    }

    public var isAuthenticationProblem: Bool {
        switch self {
        case .unauthorized, .loginRequired: return true
        default: return false
        }
    }

    /// Maps a URLError to a PVE error (certificate errors are handled separately).
    public static func from(urlError: URLError) -> PVEError {
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .network(.offline)
        case .timedOut:
            return .network(.timedOut)
        case .cannotFindHost, .dnsLookupFailed:
            return .network(.cannotFindHost)
        case .cannotConnectToHost:
            return .network(.cannotConnect)
        case .networkConnectionLost:
            return .network(.connectionLost)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired:
            return .network(.tls(urlError.localizedDescription))
        default:
            return .network(.other(urlError.localizedDescription))
        }
    }
}
