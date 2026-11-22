import Foundation

/// `Authorization: PVEAPIToken=<user>@<realm>!<tokenid>=<secret>`
public struct APIToken: Sendable, Hashable {
    /// Full user id including realm, e.g. `root@pam`.
    public var userID: String
    public var tokenID: String
    public var secret: String

    public init(userID: String, tokenID: String, secret: String) {
        self.userID = userID.trimmingCharacters(in: .whitespaces)
        self.tokenID = tokenID.trimmingCharacters(in: .whitespaces)
        self.secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `user@realm!tokenid`, also the auth id PVE reports for token sessions.
    public var fullTokenID: String { "\(userID)!\(tokenID)" }

    public var authorizationHeader: String { "PVEAPIToken=\(fullTokenID)=\(secret)" }

    /// Accepts the pasted form `user@realm!tokenid` and splits it.
    public static func split(fullTokenID: String) -> (userID: String, tokenID: String)? {
        let parts = fullTokenID.split(separator: "!", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0].contains("@"), !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }
}

/// Username / password login parameters.
public struct PasswordAccount: Sendable, Hashable, Codable {
    public var username: String
    public var realm: String

    public init(username: String, realm: String = "pam") {
        self.username = username.trimmingCharacters(in: .whitespaces)
        self.realm = realm.trimmingCharacters(in: .whitespaces)
    }

    /// `user@realm`. If the user already typed a realm it wins.
    public var userID: String {
        if username.contains("@") { return username }
        let realm = realm.isEmpty ? "pam" : realm
        return "\(username)@\(realm)"
    }
}
