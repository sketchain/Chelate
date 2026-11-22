import Foundation
import PVEKit

/// Persisted (non-secret) configuration of one PVE server. Secrets live in the Keychain.
struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    enum AuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
        case apiToken
        case password
        var id: String { rawValue }
    }

    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = ServerEndpoint.defaultPort
    var authMethod: AuthMethod = .password

    /// Password login: user name without realm (or with, then realm is ignored).
    var username: String = "root"
    var realm: String = "pam"
    var rememberPassword: Bool = false

    /// API token: `user@realm` and token id.
    var tokenUserID: String = "root@pam"
    var tokenID: String = ""

    /// SHA-256 fingerprint the user confirmed for this server.
    var pinnedFingerprint: CertificateFingerprint?

    init() {}

    enum CodingKeys: String, CodingKey {
        case id, name, host, port, authMethod, username, realm, rememberPassword, tokenUserID, tokenID, pinnedFingerprint
    }

    /// Tolerant decoding so new fields never break existing installs.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? ServerEndpoint.defaultPort
        authMethod = (try? c.decodeIfPresent(AuthMethod.self, forKey: .authMethod)) ?? .password
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? "root"
        realm = try c.decodeIfPresent(String.self, forKey: .realm) ?? "pam"
        rememberPassword = try c.decodeIfPresent(Bool.self, forKey: .rememberPassword) ?? false
        tokenUserID = try c.decodeIfPresent(String.self, forKey: .tokenUserID) ?? "root@pam"
        tokenID = try c.decodeIfPresent(String.self, forKey: .tokenID) ?? ""
        pinnedFingerprint = try? c.decodeIfPresent(CertificateFingerprint.self, forKey: .pinnedFingerprint)
    }

    var endpoint: ServerEndpoint { ServerEndpoint(host: host, port: port) }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? host : trimmed
    }

    var account: PasswordAccount { PasswordAccount(username: username, realm: realm) }

    /// The auth id shown in the UI.
    var authIDDescription: String {
        switch authMethod {
        case .password: return account.userID
        case .apiToken: return "\(tokenUserID)!\(tokenID)"
        }
    }
}
