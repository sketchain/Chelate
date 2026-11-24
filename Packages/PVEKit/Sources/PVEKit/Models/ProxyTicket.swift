import Foundation

/// Response of `termproxy` / `vncproxy`.
public struct ProxyTicket: Decodable, Sendable, Hashable {
    /// Auth id the ticket was issued for (`user@realm` or `user@realm!token`).
    public var user: String
    public var ticket: String
    public var port: Int
    public var upid: String?
    /// Only for `vncproxy` with `generate-password=1`.
    public var password: String?

    enum CodingKeys: String, CodingKey { case user, ticket, port, upid, password }

    public init(user: String, ticket: String, port: Int, upid: String? = nil, password: String? = nil) {
        self.user = user
        self.ticket = ticket
        self.port = port
        self.upid = upid
        self.password = password
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = c.flexibleString(.user) ?? ""
        ticket = try c.decode(String.self, forKey: .ticket)
        guard let port = c.flexibleInt(.port) else {
            throw DecodingError.keyNotFound(CodingKeys.port, .init(codingPath: c.codingPath, debugDescription: "missing port"))
        }
        self.port = port
        upid = c.flexibleString(.upid)
        password = c.flexibleString(.password)
    }
}
