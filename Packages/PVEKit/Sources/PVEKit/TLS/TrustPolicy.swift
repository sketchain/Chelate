import Foundation

/// SHA-256 fingerprint of a DER encoded certificate.
public struct CertificateFingerprint: Sendable, Hashable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Parses `AB:CD:...`, `abcd...` or `AB CD ...`. Returns nil unless it is exactly 32 bytes.
    public init?(string: String) {
        let hex = string.filter { $0.isHexDigit }
        guard hex.count == 64, string.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == " " }) else {
            return nil
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.bytes = bytes
    }

    /// Uppercase, colon separated (the format PVE shows under Node > Certificates).
    public var description: String {
        bytes.map { byte in
            let hex = String(byte, radix: 16, uppercase: true)
            return hex.count == 1 ? "0" + hex : hex
        }.joined(separator: ":")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = CertificateFingerprint(string: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid fingerprint")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// What the user sees when asked to trust a certificate.
public struct CertificateInfo: Sendable, Hashable, Codable {
    public var fingerprint: CertificateFingerprint
    public var subjectSummary: String?
    public var host: String

    public init(fingerprint: CertificateFingerprint, subjectSummary: String?, host: String) {
        self.fingerprint = fingerprint
        self.subjectSummary = subjectSummary
        self.host = host
    }
}

/// Pure trust decision used by every connection path (REST, WebSocket, WKWebView).
///
/// - No pin: accept iff the system trusts the chain; otherwise report `untrusted` so the UI can
///   show the fingerprint and ask.
/// - Pinned: accept iff the leaf fingerprint equals the pin, regardless of system trust. A
///   different fingerprint is always reported as `fingerprintMismatch`, never silently accepted.
public enum TrustPolicy {
    public enum Decision: Sendable, Hashable {
        case accept
        case reject(CertificateTrustFailure)
    }

    public static func evaluate(
        systemTrusted: Bool,
        presented: CertificateInfo,
        pinned: CertificateFingerprint?
    ) -> Decision {
        if let pinned {
            if pinned == presented.fingerprint {
                return .accept
            }
            return .reject(.fingerprintMismatch(expected: pinned, presented: presented))
        }
        if systemTrusted {
            return .accept
        }
        return .reject(.untrusted(presented))
    }
}

/// Thread-safe holder for the current pin of one server plus the most recent rejection, shared
/// between the URLSession delegate, WebSocket tasks and the WKWebView navigation delegate.
public final class TrustEvaluator: @unchecked Sendable {
    private let lock = NSLock()
    private var _pinned: CertificateFingerprint?
    private var _lastFailure: CertificateTrustFailure?

    public init(pinned: CertificateFingerprint?) {
        _pinned = pinned
    }

    public var pinned: CertificateFingerprint? {
        get { lock.withLock { _pinned } }
        set { lock.withLock { _pinned = newValue } }
    }

    /// Evaluates and remembers the failure (if any). Returns whether to proceed.
    @discardableResult
    public func evaluate(systemTrusted: Bool, presented: CertificateInfo) -> Bool {
        lock.withLock {
            switch TrustPolicy.evaluate(systemTrusted: systemTrusted, presented: presented, pinned: _pinned) {
            case .accept:
                return true
            case .reject(let failure):
                _lastFailure = failure
                return false
            }
        }
    }

    /// Returns and clears the last recorded failure.
    public func takeLastFailure() -> CertificateTrustFailure? {
        lock.withLock {
            defer { _lastFailure = nil }
            return _lastFailure
        }
    }
}
