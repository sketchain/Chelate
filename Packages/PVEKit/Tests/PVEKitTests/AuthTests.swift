import Foundation
import Testing
@testable import PVEKit

private let endpoint = ServerEndpoint(host: "pve.example", port: 8006)

@Suite("Authentication")
struct AuthTests {
    @Test func apiTokenHeader() async throws {
        let token = APIToken(userID: "root@pam", tokenID: "chelate", secret: " 12345678-aaaa-bbbb-cccc-1234567890ab\n")
        #expect(token.authorizationHeader == "PVEAPIToken=root@pam!chelate=12345678-aaaa-bbbb-cccc-1234567890ab")
        let session = AuthSession(mode: .apiToken(token), endpoint: endpoint, transport: MockTransport())
        let headers = try await session.headers(isWrite: true)
        #expect(headers == ["Authorization": token.authorizationHeader])
        #expect(session.authID == "root@pam!chelate")
        #expect(session.usesAPIToken)

        let split = try #require(APIToken.split(fullTokenID: "alice@pve!ci"))
        #expect(split.userID == "alice@pve")
        #expect(split.tokenID == "ci")
        #expect(APIToken.split(fullTokenID: "alice!ci") == nil)
    }

    @Test func passwordAccountUserID() {
        #expect(PasswordAccount(username: "root").userID == "root@pam")
        #expect(PasswordAccount(username: "alice", realm: "pve").userID == "alice@pve")
        #expect(PasswordAccount(username: "bob@ldap", realm: "pam").userID == "bob@ldap")
        #expect(PasswordAccount(username: "root", realm: "").userID == "root@pam")
    }

    @Test func passwordLogin() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_ok")
        let session = AuthSession(mode: .password(PasswordAccount(username: "root")), endpoint: endpoint, transport: transport, now: { fixtureTicketDate })
        let ticket = try await session.login(password: "s3cr=t&x")

        #expect(ticket.username == "root@pam")
        #expect(ticket.csrfToken == "6921A3F0:Y3NyZnRva2VuLXNpZ25hdHVyZQ")
        #expect(ticket.issuedAt == fixtureTicketDate)

        let request = try #require(transport.recorded.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://pve.example:8006/api2/json/access/ticket")
        #expect(request.formFields == ["username": "root@pam", "password": "s3cr=t&x", "new-format": "1"])
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)

        let readHeaders = try await session.headers(isWrite: false)
        #expect(readHeaders["Cookie"] == "PVEAuthCookie=PVE%3Aroot%40pam%3A6921A3F0%3A%3AQmFzZTY0U2lnbmF0dXJlPT0%3D")
        #expect(readHeaders["CSRFPreventionToken"] == nil)
        let writeHeaders = try await session.headers(isWrite: true)
        #expect(writeHeaders["CSRFPreventionToken"] == "6921A3F0:Y3NyZnRva2VuLXNpZ25hdHVyZQ")
    }

    @Test func wrongPassword() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 401, body: #"{"data":null,"message":"authentication failure\n"}"#)
        let session = AuthSession(mode: .password(PasswordAccount(username: "root")), endpoint: endpoint, transport: transport)
        await #expect(throws: PVEError.unauthorized(message: "authentication failure")) {
            try await session.login(password: "nope")
        }
        #expect(await session.currentTicket == nil)
    }

    @Test func tfaChallengeParsing() throws {
        let response = try Fixture.decode(AuthSession.TicketResponse.self, "ticket_tfa_challenge")
        #expect(response.needTFA)
        let challenge = try TFAChallenge(ticket: try #require(response.ticket), username: response.username)
        #expect(challenge.totp)
        #expect(challenge.webauthn)
        #expect(!challenge.u2f)
        #expect(!challenge.yubico)
        #expect(challenge.recoveryKeysAvailable == [0, 1, 3])
        #expect(challenge.supportedMethods == [.totp, .recovery])

        let webauthnOnly = try Fixture.decode(AuthSession.TicketResponse.self, "ticket_tfa_webauthn_only")
        let other = try TFAChallenge(ticket: try #require(webauthnOnly.ticket), username: webauthnOnly.username)
        #expect(other.supportedMethods.isEmpty)
        #expect(other.hasRecoveryConfiguredButExhausted)

        #expect(throws: PVEError.self) {
            _ = try TFAChallenge(ticket: "PVE:root@pam:6921A3F0::sig", username: "root@pam")
        }
    }

    @Test func tfaResponses() {
        #expect(TFAResponse.totp("123 456").passwordValue == "totp:123456")
        #expect(TFAResponse.recovery(" abcd-ef01 \n").passwordValue == "recovery:abcd-ef01")
    }

    @Test func tfaLoginFlow() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_tfa_challenge")
        try transport.enqueue("ticket_tfa_ok")
        let prompted = Counter()
        let hooks = AuthHooks(provideTFA: { challenge in
            prompted.increment()
            #expect(challenge.username == "alice@pve")
            return .totp("654321")
        })
        let session = AuthSession(mode: .password(PasswordAccount(username: "alice", realm: "pve")), endpoint: endpoint, transport: transport, hooks: hooks)
        let ticket = try await session.login(password: "pw")
        #expect(prompted.value == 1)
        #expect(ticket.username == "alice@pve")
        #expect(ticket.ticket == "PVE:alice@pve:6921A400::QWxpY2VTaWduYXR1cmU=")
        #expect(ticket.csrfToken == "6921A400:YWxpY2Vjc3Jm")

        let requests = transport.recorded
        #expect(requests.count == 2)
        let second = requests[1].formFields
        #expect(second["username"] == "alice@pve")
        #expect(second["password"] == "totp:654321")
        #expect(second["tfa-challenge"]?.hasPrefix("PVE:!tfa!%7B") == true)
        #expect(second["otp"] == nil)
    }

    @Test func tfaCancelled() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_tfa_challenge")
        let session = AuthSession(mode: .password(PasswordAccount(username: "alice", realm: "pve")), endpoint: endpoint, transport: transport)
        await #expect(throws: PVEError.tfaCancelled) {
            try await session.login(password: "pw")
        }
        #expect(transport.recorded.count == 1)
    }

    @Test func tfaUnsupported() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_tfa_webauthn_only")
        let session = AuthSession(mode: .password(PasswordAccount(username: "bob", realm: "pve")), endpoint: endpoint, transport: transport)
        await #expect(throws: PVEError.tfaUnsupported) {
            try await session.login(password: "pw")
        }
    }
}

@Suite("Ticket renewal")
struct TicketRenewalTests {
    let policy = TicketRenewalPolicy()

    func ticket(issued: Date) -> PVETicket {
        PVETicket(username: "root@pam", ticket: "PVE:root@pam:6921A3F0::sig", csrfToken: "csrf", issuedAt: issued)
    }

    @Test func ticketTimestampParsing() {
        #expect(PVETicket.issueDate(of: "PVE:root@pam:6921A3F0::sig") == fixtureTicketDate)
        #expect(PVETicket.issueDate(of: "PVE:alice@pve!tok:6921A3F0::sig") == fixtureTicketDate)
        #expect(PVETicket.issueDate(of: "garbage") == nil)
        #expect(PVETicket.isTFAChallengeTicket("PVE:!tfa!%7B%7D:6921A3F0::sig"))
    }

    @Test func policyThresholds() {
        let issued = fixtureTicketDate
        #expect(policy.action(for: nil, now: issued) == .expired)
        #expect(policy.action(for: ticket(issued: issued), now: issued.addingTimeInterval(10)) == .useAsIs)
        #expect(policy.action(for: ticket(issued: issued), now: issued.addingTimeInterval(3599)) == .useAsIs)
        #expect(policy.action(for: ticket(issued: issued), now: issued.addingTimeInterval(3600)) == .renew)
        #expect(policy.action(for: ticket(issued: issued), now: issued.addingTimeInterval(7000)) == .renew)
        #expect(policy.action(for: ticket(issued: issued), now: issued.addingTimeInterval(7080)) == .expired)
        #expect(policy.action(for: ticket(issued: issued), now: issued.addingTimeInterval(-1000)) == .renew)
        #expect(policy.expiryDate(of: ticket(issued: issued)) == issued.addingTimeInterval(7200))
    }

    @Test func renewsWithOldTicketAsPassword() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_ok")
        try transport.enqueue("ticket_renewed")
        let clock = TestClock(fixtureTicketDate)
        let changes = Counter()
        let session = AuthSession(
            mode: .password(PasswordAccount(username: "root")),
            endpoint: endpoint,
            transport: transport,
            hooks: AuthHooks(ticketChanged: { _ in changes.increment() }),
            now: { clock.now }
        )
        let first = try await session.login(password: "pw")
        clock.advance(30 * 60)
        #expect(try await session.validTicket() == first) // no request
        #expect(transport.recorded.count == 1)

        clock.advance(45 * 60) // 75 min old → renew
        let renewed = try await session.validTicket()
        #expect(renewed.ticket == "PVE:root@pam:6921B200::UmVuZXdlZFNpZ25hdHVyZQ==")
        #expect(renewed.issuedAt == Date(timeIntervalSince1970: 0x6921B200))
        let renewal = transport.recorded[1].formFields
        #expect(renewal["username"] == "root@pam")
        #expect(renewal["password"] == first.ticket)
        #expect(changes.value == 2)
    }

    @Test func expiredTicketUsesRememberedPassword() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_renewed")
        let clock = TestClock(fixtureTicketDate.addingTimeInterval(3 * 3600))
        let session = AuthSession(
            mode: .password(PasswordAccount(username: "root")),
            endpoint: endpoint,
            transport: transport,
            hooks: AuthHooks(rememberedPassword: { "remembered" }),
            now: { clock.now }
        )
        await session.restore(ticket(issued: fixtureTicketDate))
        let ticket = try await session.validTicket()
        #expect(ticket.ticket.hasPrefix("PVE:root@pam:6921B200"))
        #expect(transport.recorded.count == 1)
        #expect(transport.recorded[0].formFields["password"] == "remembered")
    }

    @Test func expiredWithoutRememberedPasswordRequiresLogin() async throws {
        let transport = MockTransport()
        let clock = TestClock(fixtureTicketDate.addingTimeInterval(3 * 3600))
        let session = AuthSession(mode: .password(PasswordAccount(username: "root")), endpoint: endpoint, transport: transport, now: { clock.now })
        await session.restore(ticket(issued: fixtureTicketDate))
        await #expect(throws: PVEError.loginRequired) {
            _ = try await session.validTicket()
        }
        #expect(transport.recorded.isEmpty)
        #expect(await session.currentTicket == nil)
    }

    @Test func rejectedRenewalFallsBackToPassword() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 401, body: #"{"data":null}"#)
        try transport.enqueue("ticket_renewed")
        let clock = TestClock(fixtureTicketDate.addingTimeInterval(5000))
        let session = AuthSession(
            mode: .password(PasswordAccount(username: "root")),
            endpoint: endpoint,
            transport: transport,
            hooks: AuthHooks(rememberedPassword: { "remembered" }),
            now: { clock.now }
        )
        await session.restore(ticket(issued: fixtureTicketDate))
        _ = try await session.validTicket()
        #expect(transport.recorded.map { $0.formFields["password"] } == ["PVE:root@pam:6921A3F0::sig", "remembered"])
    }

    @Test func expiredReloginWithTFAPromptsAgain() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_tfa_challenge")
        try transport.enqueue("ticket_tfa_ok")
        let prompted = Counter()
        let clock = TestClock(fixtureTicketDate.addingTimeInterval(3 * 3600))
        let session = AuthSession(
            mode: .password(PasswordAccount(username: "alice", realm: "pve")),
            endpoint: endpoint,
            transport: transport,
            hooks: AuthHooks(
                rememberedPassword: { "pw" },
                provideTFA: { _ in prompted.increment(); return .recovery("aaaa-bbbb") }
            ),
            now: { clock.now }
        )
        await session.restore(PVETicket(username: "alice@pve", ticket: "PVE:alice@pve:6921A3F0::x", csrfToken: "c", issuedAt: fixtureTicketDate))
        let ticket = try await session.validTicket()
        #expect(ticket.username == "alice@pve")
        #expect(prompted.value == 1)
        #expect(transport.recorded[1].formFields["password"] == "recovery:aaaa-bbbb")
    }

    @Test func concurrentCallersShareOneRenewal() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_renewed")
        let clock = TestClock(fixtureTicketDate.addingTimeInterval(4000))
        let session = AuthSession(mode: .password(PasswordAccount(username: "root")), endpoint: endpoint, transport: transport, now: { clock.now })
        await session.restore(ticket(issued: fixtureTicketDate))
        async let a = session.validTicket()
        async let b = session.validTicket()
        async let c = session.validTicket()
        let results = try await [a, b, c]
        #expect(Set(results.map(\.ticket)).count == 1)
        #expect(transport.recorded.count == 1)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
