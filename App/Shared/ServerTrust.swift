import CryptoKit
import Foundation
import PVEKit
import Security

/// Bridges `SecTrust` to PVEKit's `TrustPolicy`. Used by URLSession (REST), the WebSocket
/// sessions and the WKWebView navigation delegate, so every path makes the same decision.
enum ServerTrust {
    static func certificateInfo(for trust: SecTrust, host: String) -> CertificateInfo? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return nil
        }
        let der = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: der)
        let summary = SecCertificateCopySubjectSummary(leaf) as String?
        return CertificateInfo(fingerprint: CertificateFingerprint(bytes: Array(digest)), subjectSummary: summary, host: host)
    }

    /// Evaluates a server trust challenge. Returns the disposition to hand back to the system.
    static func handle(
        _ challenge: URLAuthenticationChallenge,
        evaluator: TrustEvaluator
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        let host = challenge.protectionSpace.host
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        var error: CFError?
        let systemTrusted = SecTrustEvaluateWithError(trust, &error)
        guard let info = certificateInfo(for: trust, host: host) else {
            return (.cancelAuthenticationChallenge, nil)
        }
        if evaluator.evaluate(systemTrusted: systemTrusted, presented: info) {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}

/// URLSession delegate for REST calls.
final class TrustingSessionDelegate: NSObject, URLSessionDelegate {
    let evaluator: TrustEvaluator

    init(evaluator: TrustEvaluator) {
        self.evaluator = evaluator
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrust.handle(challenge, evaluator: evaluator)
    }
}

enum SessionFactory {
    static func makeSession(evaluator: TrustEvaluator) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: TrustingSessionDelegate(evaluator: evaluator), delegateQueue: nil)
    }
}
