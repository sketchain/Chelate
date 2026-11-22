import Foundation

/// A PVE authentication ticket (`PVEAuthCookie`) with its CSRF token.
public struct PVETicket: Sendable, Hashable, Codable {
    public var username: String
    public var ticket: String
    public var csrfToken: String
    /// When the ticket was issued (taken from the ticket itself when possible).
    public var issuedAt: Date

    public init(username: String, ticket: String, csrfToken: String, issuedAt: Date) {
        self.username = username
        self.ticket = ticket
        self.csrfToken = csrfToken
        self.issuedAt = issuedAt
    }

    /// Ticket layout: `PVE:<userid>:<hex timestamp>::<signature>`.
    public static func issueDate(of ticket: String) -> Date? {
        let parts = ticket.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "PVE", let seconds = UInt64(parts[2], radix: 16) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// `PVE:!tfa!...` tickets are first-factor-only challenge tickets.
    public static func isTFAChallengeTicket(_ ticket: String) -> Bool {
        ticket.hasPrefix("PVE:!tfa!")
    }

    /// Cookie header value. PVE `uri_unescape`s the cookie, so escape it the same way.
    public var cookieHeader: String {
        "PVEAuthCookie=\(FormEncoding.escape(ticket))"
    }
}

/// Decides when a ticket must be renewed. PVE tickets live 2 hours; a still valid ticket can be
/// exchanged for a fresh one by posting it as the password to `/access/ticket`.
public struct TicketRenewalPolicy: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        case useAsIs
        case renew
        case expired
    }

    public var lifetime: TimeInterval
    public var renewAfter: TimeInterval
    /// Safety margin for clock skew and request latency.
    public var expiryMargin: TimeInterval

    public init(lifetime: TimeInterval = 7200, renewAfter: TimeInterval = 3600, expiryMargin: TimeInterval = 120) {
        self.lifetime = lifetime
        self.renewAfter = renewAfter
        self.expiryMargin = expiryMargin
    }

    public func action(for ticket: PVETicket?, now: Date) -> Action {
        guard let ticket else { return .expired }
        let age = now.timeIntervalSince(ticket.issuedAt)
        if age >= lifetime - expiryMargin { return .expired }
        if age >= renewAfter { return .renew }
        // A ticket from the future means the device clock is off; renewing is harmless.
        if age < -300 { return .renew }
        return .useAsIs
    }

    public func expiryDate(of ticket: PVETicket) -> Date {
        ticket.issuedAt.addingTimeInterval(lifetime)
    }
}
