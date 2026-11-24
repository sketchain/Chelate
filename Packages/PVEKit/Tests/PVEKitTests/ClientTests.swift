import Foundation
import Testing
@testable import PVEKit

@Suite("API client")
struct ClientTests {
    let endpoint = ServerEndpoint(host: "pve.example")
    let guest = GuestRef(node: "pve1", type: .qemu, vmid: 100)

    func tokenClient(_ transport: MockTransport) -> PVEClient {
        let auth = AuthSession(mode: .apiToken(APIToken(userID: "root@pam", tokenID: "t", secret: "s")), endpoint: endpoint, transport: transport)
        return PVEClient(endpoint: endpoint, auth: auth, transport: transport)
    }

    @Test func endpointURLs() {
        #expect(endpoint.apiBaseURL.absoluteString == "https://pve.example:8006/api2/json")
        let v6 = ServerEndpoint(host: "fd00::10", port: 443)
        #expect(v6.apiBaseURL.absoluteString == "https://[fd00::10]:443/api2/json")
        #expect(ServerEndpoint(host: "[fd00::10]").urlHost == "[fd00::10]")
        #expect(ServerEndpoint(host: "  10.0.0.2 ").isValid)
        #expect(!ServerEndpoint(host: "").isValid)
        #expect(!ServerEndpoint(host: "pve", port: 70000).isValid)
        #expect(!ServerEndpoint(host: "https://pve").isValid)
        #expect(PathBuilder.path("nodes", "pve1", "tasks", "UPID:pve1:1:2:3:x:y:root@pam:", "status")
            == "/nodes/pve1/tasks/UPID%3Apve1%3A1%3A2%3A3%3Ax%3Ay%3Aroot%40pam%3A/status")
    }

    @Test func clusterResourcesRequest() async throws {
        let transport = MockTransport()
        try transport.enqueue("cluster_resources")
        let resources = try await tokenClient(transport).clusterResources()
        #expect(resources.count == 11)
        let request = try #require(transport.recorded.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://pve.example:8006/api2/json/cluster/resources")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "PVEAPIToken=root@pam!t=s")
    }

    @Test func powerActionReturnsUPID() async throws {
        let transport = MockTransport()
        try transport.enqueue("upid_result")
        let upid = try await tokenClient(transport).power(.stop, guest: guest)
        #expect(UPID(upid)?.type == "qmstart")
        let request = try #require(transport.recorded.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api2/json/nodes/pve1/qemu/100/status/stop")
    }

    @Test func snapshotRequests() async throws {
        let transport = MockTransport()
        try transport.enqueue("upid_result")
        try transport.enqueue("upid_result")
        try transport.enqueue("upid_result")
        let client = tokenClient(transport)
        _ = try await client.createSnapshot(guest, name: "pre-update", description: "中文 & more", includeRAM: true)
        _ = try await client.rollbackSnapshot(guest, name: "pre-update")
        _ = try await client.deleteSnapshot(GuestRef(node: "pve1", type: .lxc, vmid: 200), name: "base")
        let r = transport.recorded
        #expect(r[0].formFields == ["snapname": "pre-update", "description": "中文 & more", "vmstate": "1"])
        #expect(r[1].url?.path == "/api2/json/nodes/pve1/qemu/100/snapshot/pre-update/rollback")
        #expect(r[1].httpMethod == "POST")
        #expect(r[2].url?.path == "/api2/json/nodes/pve1/lxc/200/snapshot/base")
        #expect(r[2].httpMethod == "DELETE")
    }

    @Test func lxcSnapshotIgnoresVMState() async throws {
        let transport = MockTransport()
        try transport.enqueue("upid_result")
        _ = try await tokenClient(transport).createSnapshot(GuestRef(node: "pve1", type: .lxc, vmid: 200), name: "s1", description: nil, includeRAM: true)
        #expect(transport.recorded[0].formFields == ["snapname": "s1"])
    }

    @Test func rrdQuery() async throws {
        let transport = MockTransport()
        try transport.enqueue("rrd_guest")
        _ = try await tokenClient(transport).guestRRD(guest, timeframe: .week)
        let url = try #require(transport.recorded.first?.url)
        #expect(url.absoluteString == "https://pve.example:8006/api2/json/nodes/pve1/qemu/100/rrddata?timeframe=week&cf=AVERAGE")
    }

    @Test func forbiddenIsDistinct() async throws {
        let transport = MockTransport()
        try transport.enqueue("error_forbidden", status: 403)
        await #expect(throws: PVEError.forbidden(message: "Permission check failed (/vms/100, VM.PowerMgmt)")) {
            _ = try await tokenClient(transport).power(.start, guest: guest)
        }
    }

    @Test func ticketClientRetriesOnceAfter401() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_ok") // login
        transport.enqueue(status: 401, body: "") // ticket rejected (e.g. server restarted keys)
        try transport.enqueue("ticket_renewed") // re-login with remembered password
        try transport.enqueue("version")
        let clock = TestClock(fixtureTicketDate)
        let auth = AuthSession(
            mode: .password(PasswordAccount(username: "root")),
            endpoint: endpoint,
            transport: transport,
            hooks: AuthHooks(rememberedPassword: { "pw" }),
            now: { clock.now }
        )
        try await auth.login(password: "pw")
        let client = PVEClient(endpoint: endpoint, auth: auth, transport: transport)
        let version = try await client.version()
        #expect(version.version == "9.2.1")
        let r = transport.recorded
        #expect(r.count == 4)
        #expect(r[3].value(forHTTPHeaderField: "Cookie")?.contains("6921B200") == true)
    }

    @Test func writeRequestsCarryCSRF() async throws {
        let transport = MockTransport()
        try transport.enqueue("ticket_ok")
        try transport.enqueue("upid_result")
        let auth = AuthSession(mode: .password(PasswordAccount(username: "root")), endpoint: endpoint, transport: transport, now: { fixtureTicketDate })
        try await auth.login(password: "pw")
        _ = try await PVEClient(endpoint: endpoint, auth: auth, transport: transport).power(.start, guest: guest)
        let request = transport.recorded[1]
        #expect(request.value(forHTTPHeaderField: "CSRFPreventionToken") == "6921A3F0:Y3NyZnRva2VuLXNpZ25hdHVyZQ")
        #expect(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("PVEAuthCookie=PVE%3Aroot%40pam") == true)
    }

    @Test func webSocketRequests() async throws {
        let transport = MockTransport()
        let client = tokenClient(transport)
        let ticket = try Fixture.decode(ProxyTicket.self, "termproxy")
        let node = try await client.termProxyWebSocketRequest(.nodeShell(node: "pve1"), ticket: ticket)
        #expect(node.url?.absoluteString == "wss://pve.example:8006/api2/json/nodes/pve1/vncwebsocket?port=5900&vncticket=PVEVNC%3A6921A3F0%3A%3AdGVybXByb3h5c2lnbmF0dXJl")
        #expect(node.value(forHTTPHeaderField: "Authorization") == "PVEAPIToken=root@pam!t=s")
        #expect(node.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "binary")

        let lxc = try await client.termProxyWebSocketRequest(.lxc(GuestRef(node: "pve1", type: .lxc, vmid: 200)), ticket: ticket)
        #expect(lxc.url?.path == "/api2/json/nodes/pve1/lxc/200/vncwebsocket")

        let vnc = try await client.vncWebSocketRequest(guest, ticket: ticket)
        #expect(vnc.url?.path == "/api2/json/nodes/pve1/qemu/100/vncwebsocket")
    }

    @Test func vncProxyRequestsWebsocketMode() async throws {
        let transport = MockTransport()
        try transport.enqueue("vncproxy")
        let ticket = try await tokenClient(transport).vncProxy(guest)
        #expect(ticket.port == 5901)
        #expect(transport.recorded[0].formFields == ["websocket": "1"])
        #expect(transport.recorded[0].url?.path == "/api2/json/nodes/pve1/qemu/100/vncproxy")
    }

    @Test func termProxyPaths() async throws {
        let transport = MockTransport()
        try transport.enqueue("termproxy")
        try transport.enqueue("termproxy")
        let client = tokenClient(transport)
        _ = try await client.termProxy(.nodeShell(node: "pve1"))
        _ = try await client.termProxy(.lxc(GuestRef(node: "pve1", type: .lxc, vmid: 200)))
        #expect(transport.recorded.map { $0.url!.path } == ["/api2/json/nodes/pve1/termproxy", "/api2/json/nodes/pve1/lxc/200/termproxy"])
    }

    @Test func consoleAdvisory() {
        #expect(ConsoleAdvisory.evaluate(target: .nodeShell(node: "pve1"), authID: "root@pam", usesToken: false) == .none)
        #expect(ConsoleAdvisory.evaluate(target: .nodeShell(node: "pve1"), authID: "root@pam!t", usesToken: true) == .nodeShellRequiresLogin(viaToken: true))
        #expect(ConsoleAdvisory.evaluate(target: .nodeShell(node: "pve1"), authID: "alice@pve", usesToken: false) == .nodeShellRequiresLogin(viaToken: false))
        #expect(ConsoleAdvisory.evaluate(target: .lxc(GuestRef(node: "n", type: .lxc, vmid: 1)), authID: "x@pve!t", usesToken: true) == .none)
    }

    @Test func powerActionAvailability() {
        #expect(PowerAction.available(for: .qemu).contains(.suspend))
        #expect(!PowerAction.available(for: .lxc).contains(.suspend))
        #expect(PowerAction.stop.isDestructive)
        #expect(PowerAction.reboot.isDestructive)
        #expect(!PowerAction.start.isDestructive)
    }
}
