import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Callbacks into the UI / Keychain layer.
public struct AuthHooks: Sendable {
    /// Returns the remembered password, if the user opted in.
    public var rememberedPassword: @Sendable () async -> String?
    /// Asks the user for a second factor. Throw `PVEError.tfaCancelled` when dismissed.
    public var provideTFA: @Sendable (TFAChallenge) async throws -> TFAResponse
    /// Called whenever the ticket changes (persist it, or clear it on nil).
    public var ticketChanged: @Sendable (PVETicket?) async -> Void

    public init(
        rememberedPassword: @escaping @Sendable () async -> String? = { nil },
        provideTFA: @escaping @Sendable (TFAChallenge) async throws -> TFAResponse = { _ in throw PVEError.tfaCancelled },
        ticketChanged: @escaping @Sendable (PVETicket?) async -> Void = { _ in }
    ) {
        self.rememberedPassword = rememberedPassword
        self.provideTFA = provideTFA
        self.ticketChanged = ticketChanged
    }
}

/// Owns authentication state for one server.
///
/// - API token: static header, nothing to refresh.
/// - Password: `POST /access/ticket`; TFA via `tfa-challenge`; renewal by posting the current
///   ticket as password before it expires; full re-login with the remembered password once it
///   has expired (TFA accounts are prompted again through `AuthHooks.provideTFA`).
public actor AuthSession {
    public enum Mode: Sendable, Hashable {
        case apiToken(APIToken)
        case password(PasswordAccount)
    }

    public nonisolated let mode: Mode
    private let endpoint: ServerEndpoint
    private let transport: any HTTPTransport
    private let policy: TicketRenewalPolicy
    private let now: @Sendable () -> Date
    private var hooks: AuthHooks

    private var ticket: PVETicket?
    private var refreshTask: Task<PVETicket, any Error>?

    public init(
        mode: Mode,
        endpoint: ServerEndpoint,
        transport: any HTTPTransport,
        hooks: AuthHooks = AuthHooks(),
        policy: TicketRenewalPolicy = TicketRenewalPolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.mode = mode
        self.endpoint = endpoint
        self.transport = transport
        self.hooks = hooks
        self.policy = policy
        self.now = now
    }

    public func setHooks(_ hooks: AuthHooks) {
        self.hooks = hooks
    }

    /// The auth id PVE will see (`user@realm` or `user@realm!token`).
    public nonisolated var authID: String {
        switch mode {
        case .apiToken(let token): return token.fullTokenID
        case .password(let account): return account.userID
        }
    }

    public nonisolated var usesAPIToken: Bool {
        if case .apiToken = mode { return true }
        return false
    }

    public var currentTicket: PVETicket? { ticket }

    /// Restores a persisted ticket (e.g. after an app relaunch).
    public func restore(_ ticket: PVETicket?) {
        self.ticket = ticket
    }

    /// Interactive login with an explicit password.
    @discardableResult
    public func login(password: String) async throws -> PVETicket {
        guard case .password(let account) = mode else { throw PVEError.invalidEndpoint }
        refreshTask?.cancel()
        refreshTask = nil
        let newTicket = try await performLogin(userID: account.userID, password: password)
        await store(newTicket)
        return newTicket
    }

    /// Clears the ticket locally.
    public func logout() async {
        refreshTask?.cancel()
        refreshTask = nil
        await store(nil)
    }

    /// Called when the server answered 401 to an authenticated request.
    public func invalidateTicket() async {
        guard case .password = mode else { return }
        await store(nil)
    }

    /// Headers for an API request.
    public func headers(isWrite: Bool) async throws -> [String: String] {
        switch mode {
        case .apiToken(let token):
            return ["Authorization": token.authorizationHeader]
        case .password:
            let ticket = try await validTicket()
            var headers = ["Cookie": ticket.cookieHeader]
            if isWrite {
                headers["CSRFPreventionToken"] = ticket.csrfToken
            }
            return headers
        }
    }

    /// Headers for a WebSocket upgrade (`vncwebsocket`).
    public func webSocketHeaders() async throws -> [String: String] {
        try await headers(isWrite: false)
    }

    /// Returns a ticket that is valid for at least a few minutes, renewing or re-logging in as
    /// needed. Concurrent callers share one in-flight refresh.
    public func validTicket() async throws -> PVETicket {
        guard case .password(let account) = mode else { throw PVEError.invalidEndpoint }
        switch policy.action(for: ticket, now: now()) {
        case .useAsIs:
            return ticket!
        case .renew, .expired:
            break
        }
        if let refreshTask {
            return try await refreshTask.value
        }
        let current = ticket
        let action = policy.action(for: current, now: now())
        let hooks = hooks
        let task = Task<PVETicket, any Error> {
            if action == .renew, let current {
                do {
                    return try await self.performLogin(userID: current.username, password: current.ticket)
                } catch PVEError.unauthorized {
                    // Fall through to a full login below.
                }
            }
            guard let password = await hooks.rememberedPassword() else {
                throw PVEError.loginRequired
            }
            return try await self.performLogin(userID: account.userID, password: password)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let newTicket = try await task.value
            await store(newTicket)
            return newTicket
        } catch PVEError.loginRequired {
            await store(nil)
            throw PVEError.loginRequired
        } catch PVEError.unauthorized(let message) {
            await store(nil)
            throw PVEError.unauthorized(message: message)
        }
    }

    // MARK: - Internals

    private func store(_ ticket: PVETicket?) async {
        self.ticket = ticket
        await hooks.ticketChanged(ticket)
    }

    struct TicketResponse: Decodable {
        let username: String
        let ticket: String?
        let csrfToken: String?
        let needTFA: Bool

        enum CodingKeys: String, CodingKey {
            case username, ticket
            case csrfToken = "CSRFPreventionToken"
            case needTFA = "NeedTFA"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            username = try container.decode(String.self, forKey: .username)
            ticket = try container.decodeIfPresent(String.self, forKey: .ticket)
            csrfToken = try container.decodeIfPresent(String.self, forKey: .csrfToken)
            needTFA = container.flexibleBool(.needTFA) ?? false
        }
    }

    /// First factor (+ second factor if requested by the server).
    private func performLogin(userID: String, password: String) async throws -> PVETicket {
        let first = try await postTicket([
            ("username", userID),
            ("password", password),
            ("new-format", "1"),
        ])
        guard let firstTicket = first.ticket else {
            throw PVEError.decoding("missing ticket")
        }
        if first.needTFA || PVETicket.isTFAChallengeTicket(firstTicket) {
            let challenge = try TFAChallenge(ticket: firstTicket, username: first.username)
            guard !challenge.supportedMethods.isEmpty else {
                throw PVEError.tfaUnsupported
            }
            let answer = try await hooks.provideTFA(challenge)
            let second = try await postTicket([
                ("username", first.username),
                ("tfa-challenge", firstTicket),
                ("password", answer.passwordValue),
            ])
            return try makeTicket(second, fallbackCSRF: first.csrfToken)
        }
        return try makeTicket(first, fallbackCSRF: nil)
    }

    private func makeTicket(_ response: TicketResponse, fallbackCSRF: String?) throws -> PVETicket {
        guard let ticket = response.ticket, !PVETicket.isTFAChallengeTicket(ticket) else {
            throw PVEError.decoding("missing ticket")
        }
        guard let csrf = response.csrfToken ?? fallbackCSRF else {
            throw PVEError.decoding("missing CSRFPreventionToken")
        }
        return PVETicket(
            username: response.username,
            ticket: ticket,
            csrfToken: csrf,
            issuedAt: PVETicket.issueDate(of: ticket) ?? now()
        )
    }

    private func postTicket(_ form: [(String, String)]) async throws -> TicketResponse {
        let request = RequestFactory.make(
            endpoint: endpoint,
            method: .post,
            path: "/access/ticket",
            query: [],
            form: form,
            headers: [:]
        )
        let (data, response) = try await transport.send(request)
        return try ResponseDecoding.decode(TicketResponse.self, data: data, response: response)
    }
}
