import Testing
@testable import PVEKit

@Suite("Log redaction")
struct LogRedactorTests {
    @Test func tokenSecret() {
        let line = "Authorization: PVEAPIToken=root@pam!ci=0b7f8a6e-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
        let redacted = LogRedactor.redact(line)
        #expect(!redacted.contains("0b7f8a6e"))
        #expect(redacted.contains("root@pam!ci"))
        #expect(LogRedactor.redact("token root@pam!ci=0b7f8a6e-1c2d-4e5f-8a9b-0c1d2e3f4a5b").contains("0b7f8a6e") == false)
    }

    @Test func ticketsAndCookies() {
        let ticket = "PVE:root@pam:6921A3F0::dGhpcyBpcyBhIHNpZ25hdHVyZQ=="
        #expect(!LogRedactor.redact("Cookie: PVEAuthCookie=\(ticket)").contains("6921A3F0"))
        #expect(!LogRedactor.redact("got ticket \(ticket) ok").contains("dGhpcyBp"))
        #expect(!LogRedactor.redact("vncticket=PVEVNC:6921A3F0::c2lnbmF0dXJl&port=5900").contains("c2lnbmF0dXJl"))
        #expect(LogRedactor.redact("vncticket=PVEVNC:6921A3F0::c2lnbmF0dXJl&port=5900").contains("port=5900"))
        #expect(!LogRedactor.redact(#"{"ticket":"PVE:u@pve:1::abc"}"#).contains("abc"))
    }

    @Test func csrfAndPasswords() {
        #expect(!LogRedactor.redact("CSRFPreventionToken: 6921A3F0:Yk9lW3sJ0sP+h1").contains("Yk9lW3"))
        #expect(!LogRedactor.redact(#"{"CSRFPreventionToken":"6921A3F0:abcdef"}"#).contains("abcdef"))
        #expect(!LogRedactor.redact("username=root@pam&password=hunter2&new-format=1").contains("hunter2"))
        let json = LogRedactor.redact(#"{"password": "p@ss w0rd", "user": "root"}"#)
        #expect(!json.contains("p@ss") && !json.contains("w0rd"))
        #expect(json.contains(#""user": "root""#))
    }

    @Test func leavesOrdinaryTextAlone() {
        let line = "2026-11-24T10:00:00Z [net] GET /nodes/pve/status → 200 (12 ms)"
        #expect(LogRedactor.redact(line) == line)
    }
}
