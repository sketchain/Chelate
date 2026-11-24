import Foundation

/// The second-factor challenge embedded in a `PVE:!tfa!<urlencoded json>:...` ticket.
///
/// Mirrors `Proxmox.window.TfaLoginWindow` (proxmox-widget-toolkit) and the proxmox-tfa
/// `TfaChallenge` struct: `{"totp":true,"recovery":[0,1,3],"webauthn":{...},"u2f":{...},"yubico":true}`.
public struct TFAChallenge: Sendable, Hashable {
    public var totp: Bool
    /// Indices of unused recovery keys; nil when recovery keys are not configured.
    public var recoveryKeysAvailable: [Int]?
    public var webauthn: Bool
    public var u2f: Bool
    public var yubico: Bool
    /// The full challenge ticket, sent back as `tfa-challenge`.
    public var ticket: String
    public var username: String

    public enum Method: String, Sendable, Hashable, CaseIterable {
        case totp
        case recovery
    }

    /// Methods this app supports and the account can use.
    public var supportedMethods: [Method] {
        var methods: [Method] = []
        if totp { methods.append(.totp) }
        if let keys = recoveryKeysAvailable, !keys.isEmpty { methods.append(.recovery) }
        return methods
    }

    public var hasRecoveryConfiguredButExhausted: Bool {
        if let keys = recoveryKeysAvailable { return keys.isEmpty }
        return false
    }

    public init(ticket: String, username: String) throws {
        self.ticket = ticket
        self.username = username
        let parts = ticket.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[1].hasPrefix("!tfa!") else {
            throw PVEError.decoding("Not a TFA challenge ticket")
        }
        let encoded = String(parts[1].dropFirst("!tfa!".count))
        guard let json = encoded.removingPercentEncoding, let data = json.data(using: .utf8) else {
            throw PVEError.decoding("Malformed TFA challenge")
        }
        let raw: [String: JSONValue]
        do {
            raw = try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            throw PVEError.decoding("Malformed TFA challenge JSON")
        }
        func present(_ key: String) -> Bool {
            switch raw[key] {
            case .none, .null?: return false
            case .bool(let value)?: return value
            default: return true
            }
        }
        totp = present("totp")
        webauthn = present("webauthn")
        u2f = present("u2f")
        yubico = present("yubico")
        if case .array(let values)? = raw["recovery"] {
            recoveryKeysAvailable = values.compactMap { $0.doubleValue.map { Int($0) } }
        } else {
            recoveryKeysAvailable = nil
        }
    }
}

/// The user's answer to a TFA challenge, sent as `password`.
public enum TFAResponse: Sendable, Hashable {
    case totp(String)
    case recovery(String)

    public var passwordValue: String {
        switch self {
        case .totp(let code):
            return "totp:\(code.filter { !$0.isWhitespace })"
        case .recovery(let key):
            return "recovery:\(key.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}
