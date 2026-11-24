import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PVEKit

/// Spot checks of the request layer generated from `Schema/pve-api-9.2.json`.
@Suite("Generated API")
struct GeneratedAPITests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try ResponseDecoding.decode(type, data: Data(json.utf8), response: Fixture.response(200))
    }

    @Test func coversTheWholeSchema() {
        let all = PVEAPI.allRequests
        #expect(all.count == 716)
        let keys = Set(all.map { "\($0.method.rawValue) \($0.pathTemplate)" })
        #expect(keys.count == all.count, "every method + path appears once")
        #expect(PVEAPI.schemaCommit == "f31f02702a101714151291e9e163dd31fe8d1aab")
        #expect(PVEAPI.schemaVersion.hasPrefix("9.2"))
    }

    @Test func guestStatusRequestAndTypedResponse() throws {
        let request = PVEAPI.GetNodesQemuStatusCurrent(node: "pve 1", vmid: 100)
        #expect(PVEAPI.GetNodesQemuStatusCurrent.method == .get)
        #expect(PVEAPI.GetNodesQemuStatusCurrent.pathTemplate == "/nodes/{node}/qemu/{vmid}/status/current")
        #expect(PVEAPI.GetNodesQemuStatusCurrent.schemaName == "vm_status")
        #expect(request.path == "/nodes/pve%201/qemu/100/status/current")
        #expect(request.parameters.isEmpty)

        let status = try Fixture.decode(PVEAPI.GetNodesQemuStatusCurrent.Response.self, "guest_status_qemu")
        #expect(status.status == "running")
        #expect(status.name == "debian-web")
        #expect(status.vmid == 100)
        #expect(status.maxmem == 4_294_967_296)
        #expect(status.cpu == 0.0215)
    }

    @Test func requiredOptionalAndEnumParameters() {
        var request = PVEAPI.PostNodesStorageDownloadUrl(node: "pve1", storage: "local", content: .iso, filename: "a.iso", url: "https://x/a.iso")
        #expect(PVEAPI.PostNodesStorageDownloadUrl.Content.allCases.map(\.rawValue).contains("vztmpl"))
        #expect(request.parameters.map(\.0) == ["content", "filename", "url"])
        request.checksumAlgorithm = .sha256
        request.checksum = "abc"
        request.verifyCertificates = false
        let fields = Dictionary(uniqueKeysWithValues: request.parameters)
        #expect(fields["checksum-algorithm"] == "sha256")
        #expect(fields["verify-certificates"] == "0")
        #expect(request.path == "/nodes/pve1/storage/local/download-url")
    }

    @Test func indexedAndArrayParameters() {
        var config = PVEAPI.PutNodesQemuConfig(node: "pve1", vmid: 101)
        config.net = [1: "virtio,bridge=vmbr1", 0: "virtio,bridge=vmbr0"]
        config.onboot = true
        config.cores = 4
        let pairs = config.parameters
        #expect(pairs.filter { $0.0.hasPrefix("net") }.map(\.0) == ["net0", "net1"])
        #expect(Dictionary(uniqueKeysWithValues: pairs)["onboot"] == "1")
        #expect(Dictionary(uniqueKeysWithValues: pairs)["cores"] == "4")
        #expect(PVEAPI.PutNodesQemuConfig.method == .put)

        let mapping = PVEAPI.PostClusterMappingPci(id: "gpu", map: ["node=a,path=0000:01:00", "node=b,path=0000:02:00"])
        #expect(mapping.parameters.filter { $0.0 == "map" }.count == 2)
    }

    @Test func trailingPathParameterNaming() {
        let delete = PVEAPI.DeleteNodesQemuSnapshotBySnapname(node: "pve1", vmid: 100, snapname: "pre update")
        #expect(PVEAPI.DeleteNodesQemuSnapshotBySnapname.method == .delete)
        #expect(delete.path == "/nodes/pve1/qemu/100/snapshot/pre%20update")
        var permissions = PVEAPI.GetAccessPermissions()
        permissions.pathParam = "/vms/100"
        #expect(permissions.parameters.map(\.0) == ["path"])
    }

    @Test func lenientResponseDecoding() throws {
        // Numbers as strings, booleans as 0/1 or strings, indexed keys.
        let config = try decode(PVEAPI.GetNodesQemuConfig.Response.self, #"""
        {"data": {"cores": "4", "onboot": 1, "name": "web", "net0": "virtio=AA:BB,bridge=vmbr0", "net2": "e1000,bridge=vmbr1", "netx": "ignored"}}
        """#)
        #expect(config.cores == 4)
        #expect(config.onboot == true)
        #expect(config.net == [0: "virtio=AA:BB,bridge=vmbr0", 2: "e1000,bridge=vmbr1"])
        #expect(config.scsi.isEmpty)

        let guests = try decode(PVEAPI.GetNodesQemu.Response.self, #"""
        {"data": [{"vmid": 100, "status": "running", "cpu": 0.12, "name": "a", "template": "0", "maxmem": 4294967296},
                  {"vmid": "101", "status": "stopped", "unexpected": {"x": 1}}]}
        """#)
        #expect(guests.map(\.vmid) == [100, 101])
        #expect(guests[0].template == false)
        #expect(guests[1].cpu == nil)
    }

    @Test func sendUsesQueryForReadsAndFormForWrites() async throws {
        let transport = MockTransport()
        transport.enqueue(status: 200, body: #"{"data": [{"vmid": 100, "status": "running"}]}"#)
        transport.enqueue(status: 200, body: #"{"data": "UPID:pve1:00001234:00000001:6921A3F0:qmstart:100:root@pam:"}"#)
        let client = PVEClient(
            endpoint: ServerEndpoint(host: "pve.example"),
            auth: AuthSession(mode: .apiToken(APIToken(userID: "root@pam", tokenID: "t", secret: "s")), endpoint: ServerEndpoint(host: "pve.example"), transport: transport),
            transport: transport
        )
        var list = PVEAPI.GetNodesQemu(node: "pve1")
        list.full = true
        let guests = try await client.send(list)
        #expect(guests.first?.status == "running")
        let upid = try await client.send(PVEAPI.PostNodesQemuStatusStart(node: "pve1", vmid: 100))
        #expect(upid.hasPrefix("UPID:"))
        #expect(transport.recorded[0].url?.absoluteString == "https://pve.example:8006/api2/json/nodes/pve1/qemu?full=1")
        #expect(transport.recorded[1].httpMethod == "POST")
        #expect(transport.recorded[1].url?.path == "/api2/json/nodes/pve1/qemu/100/status/start")
    }
}
