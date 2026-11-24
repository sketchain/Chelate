import Foundation
import Testing
@testable import PVEKit

@Suite("Storage, templates and new RRD fields")
struct StorageTests {
    let endpoint = ServerEndpoint(host: "pve.example")

    func client(_ transport: MockTransport) -> PVEClient {
        let auth = AuthSession(mode: .apiToken(APIToken(userID: "root@pam", tokenID: "t", secret: "s")), endpoint: endpoint, transport: transport)
        return PVEClient(endpoint: endpoint, auth: auth, transport: transport)
    }

    @Test func storageContentDecoding() throws {
        let items = try Fixture.decode([StorageContentItem].self, "storage_content")
        #expect(items.count == 6)
        let iso = try #require(items.first)
        #expect(iso.contentType == .iso)
        #expect(iso.fileName == "debian-13.1.0-amd64-netinst.iso")
        #expect(iso.size == 790_626_304)
        #expect(iso.ctime == Date(timeIntervalSince1970: 1_763_000_000))

        let tmpl = items[1]
        #expect(tmpl.size == 131_072_000) // numeric string
        #expect(tmpl.fileName == "debian-13-standard_13.1-2_amd64.tar.zst")

        let backup = items[2]
        #expect(backup.vmid == 200)
        #expect(backup.isProtected)
        #expect(backup.notes == "pihole nightly")
        #expect(items[3].vmid == 100)
        #expect(items[3].notes == nil)

        let groups = items.groupedByContent()
        #expect(groups.map(\.content) == ["iso", "vztmpl", "backup", "snippets"])
        #expect(groups[0].items.map(\.fileName) == ["archlinux-2026.11.01-x86_64.iso", "debian-13.1.0-amd64-netinst.iso"])
        // Backups newest first.
        #expect(groups[2].items.first?.vmid == 100)

        let zfs = try Fixture.decode([StorageContentItem].self, "storage_content_zfs")
        #expect(zfs.map(\.fileName) == ["vm-100-disk-0", "subvol-200-disk-0"])
        #expect(zfs[1].vmid == 200)
        #expect(zfs[0].ctime == nil)
        #expect(zfs.groupedByContent().map(\.content) == ["images", "rootdir"])
    }

    @Test func storageStatusDecoding() throws {
        let status = try Fixture.decode(StorageStatus.self, "storage_status")
        #expect(status.content == [.iso, .backup, .vztmpl, .snippets])
        #expect(status.active)
        #expect(!status.shared)
        #expect(abs((status.fraction ?? 0) - 0.0979) < 0.001)
        #expect(StorageContentType.parseList("rootdir, images,unknown") == [.rootdir, .images])
    }

    @Test func urlMetadata() async throws {
        let full = try Fixture.decode(URLMetadata.self, "url_metadata")
        #expect(full.filename == "debian-13.1.0-amd64-netinst.iso")
        #expect(full.size == 790_626_304)
        let partial = try Fixture.decode(URLMetadata.self, "url_metadata_partial")
        #expect(partial.filename == nil)
        #expect(partial.size == nil)

        let transport = MockTransport()
        try transport.enqueue("url_metadata")
        _ = try await client(transport).queryURLMetadata(node: "pve1", url: " https://example.com/a b.iso ", verifyCertificates: false)
        let request = try #require(transport.recorded.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/api2/json/nodes/pve1/query-url-metadata")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first { $0.name == "url" }?.value == "https://example.com/a b.iso")
        #expect(query.first { $0.name == "verify-certificates" }?.value == "0")
    }

    @Test func downloadURLRequest() async throws {
        let transport = MockTransport()
        try transport.enqueue("upid_result")
        try transport.enqueue("upid_result")
        let client = client(transport)
        let upid = try await client.downloadURL(node: "pve1", storage: "local", DownloadURLRequest(
            url: "https://example.com/x.iso", content: .iso, filename: "x.iso",
            checksum: " abc123 ", checksumAlgorithm: .sha256, verifyCertificates: true
        ))
        #expect(UPID(upid) != nil)
        _ = try await client.downloadURL(node: "pve1", storage: "local", DownloadURLRequest(
            url: "https://example.com/t.tar.zst", content: .vztmpl, filename: "t.tar.zst",
            checksum: "", checksumAlgorithm: .md5, verifyCertificates: false
        ))
        let r = transport.recorded
        #expect(r[0].httpMethod == "POST")
        #expect(r[0].url?.path == "/api2/json/nodes/pve1/storage/local/download-url")
        #expect(r[0].formFields == [
            "url": "https://example.com/x.iso", "content": "iso", "filename": "x.iso",
            "verify-certificates": "1", "checksum": "abc123", "checksum-algorithm": "sha256",
        ])
        // Empty checksum: neither checksum nor algorithm is sent.
        #expect(r[1].formFields == [
            "url": "https://example.com/t.tar.zst", "content": "vztmpl", "filename": "t.tar.zst", "verify-certificates": "0",
        ])
    }

    @Test func storageContentRequest() async throws {
        let transport = MockTransport()
        try transport.enqueue("storage_content")
        try transport.enqueue("storage_status")
        let client = client(transport)
        _ = try await client.storageContent(node: "pve1", storage: "local")
        _ = try await client.storageStatus(node: "pve1", storage: "local")
        #expect(transport.recorded[0].url?.absoluteString == "https://pve.example:8006/api2/json/nodes/pve1/storage/local/content")
        #expect(transport.recorded[1].url?.path == "/api2/json/nodes/pve1/storage/local/status")
    }

    @Test func applianceTemplates() async throws {
        let list = try Fixture.decode([ApplianceTemplate].self, "aplinfo")
        #expect(list.count == 4)
        #expect(list[0].headline == "Debian 13 (standard)")
        #expect(list[0].section == "system")
        #expect(list.sections == ["system", "mail", "turnkeylinux"])
        #expect(list.filter { $0.matches("nextcloud") }.map(\.package) == ["turnkey-nextcloud"])
        #expect(list.filter { $0.matches("DEBIAN") }.count == 3)
        #expect(list.filter { $0.matches("  ") }.count == 4)

        let transport = MockTransport()
        try transport.enqueue("aplinfo")
        try transport.enqueue("upid_result")
        let client = client(transport)
        _ = try await client.applianceTemplates(node: "pve1")
        _ = try await client.downloadApplianceTemplate(node: "pve1", storage: "local", template: list[0].template)
        #expect(transport.recorded[0].httpMethod == "GET")
        #expect(transport.recorded[0].url?.path == "/api2/json/nodes/pve1/aplinfo")
        #expect(transport.recorded[1].httpMethod == "POST")
        #expect(transport.recorded[1].formFields == ["storage": "local", "template": "debian-13-standard_13.1-2_amd64.tar.zst"])
    }

    @Test func pve9NodeRRD() throws {
        let rows = try Fixture.decode([RRDPoint].self, "rrd_node_pve9")
        #expect(rows.samples(.memoryAvailable).map(\.value) == [74_088_185_856, 73_014_444_032])
        #expect(rows.samples(.arcSize).map(\.value) == [21_474_836_480, 22_548_578_304]) // string
        #expect(rows.samples(.memoryTotal).count == 2)
        #expect(rows.hasNonZero(.arcSize))
        #expect(!rows.contains(.memoryHost))

        // Older fixture: arcsize = 0 (no ZFS) → treated as absent.
        let legacy = try Fixture.decode([RRDPoint].self, "rrd_node")
        #expect(legacy.contains(.arcSize))
        #expect(!legacy.hasNonZero(.arcSize))
        #expect(legacy.contains(.memoryAvailable))

        let qemu = try Fixture.decode([RRDPoint].self, "rrd_guest")
        #expect(qemu.samples(.memoryHost).map(\.value) == [1_400_000_000])
        let lxc = try Fixture.decode([RRDPoint].self, "rrd_lxc")
        #expect(!lxc.contains(.memoryHost))
        #expect(lxc.samples(.memoryUsed).first?.value == 134_217_728)
        #expect(lxc.samples(.memoryTotal).first?.value == 536_870_912)
    }

    @Test func nodeSystemStrings() throws {
        let status = try Fixture.decode(NodeStatus.self, "node_status")
        #expect(status.pveVersionNumber == "9.2.1")
        #expect(status.currentKernelRelease == "6.17.2-1-pve")
        #expect(status.kernelRelease == "6.17.2-1-pve")
        #expect(NodeStatus.kernelRelease(fromKVersion: "Linux 7.0.14-25-pve #1 SMP PREEMPT_DYNAMIC PMX") == "7.0.14-25-pve")
        #expect(NodeStatus.versionNumber(fromPVEVersion: "pve-manager/9.2.21/0123abcd") == "9.2.21")
        #expect(NodeStatus.versionNumber(fromPVEVersion: "9.0.3") == "9.0.3")
    }

    @Test func byteFormatting() {
        #expect(ByteFormat.string(0) == "0")
        #expect(ByteFormat.string(512) == "512 B")
        #expect(ByteFormat.string(1536) == "1.50 KiB")
        #expect(ByteFormat.string(13_421_772_800) == "12.5 GiB")
        #expect(ByteFormat.string(134_217_728_000) == "125 GiB")
        #expect(ByteFormat.string(2 * 1_099_511_627_776) == "2.00 TiB")
        #expect(ByteFormat.string(.nan) == "–")
        #expect(ByteFormat.axisLabel(0, unitIndex: 3) == "0")
        #expect(ByteFormat.axisLabel(2.5 * 1_073_741_824, unitIndex: 3) == "2.5 GiB")
        #expect(ByteFormat.axisLabel(64 * 1_073_741_824, unitIndex: 3) == "64 GiB")
    }

    @Test func niceScale() {
        let gib = 1_073_741_824.0
        let memory = NiceScale(maxValue: 125 * gib, kind: .bytes)
        #expect(memory.unitIndex == 3)
        #expect(memory.ticks.map { $0 / gib } == [0, 50, 100, 150])

        let small = NiceScale(maxValue: 3.7 * gib, kind: .bytes)
        #expect(small.ticks.map { $0 / gib } == [0, 1, 2, 3, 4])

        let cpu = NiceScale(maxValue: 0.052, kind: .fraction)
        #expect(cpu.ticks.map { ($0 * 1000).rounded() / 10 } == [0, 2, 4, 6])
        let full = NiceScale(maxValue: 0.97, kind: .fraction)
        #expect(full.upperBound >= 0.97)
        #expect(full.ticks.count <= 6)

        let zero = NiceScale(maxValue: 0, kind: .bytes)
        #expect(zero.ticks == [0, 1])
        let zeroFraction = NiceScale(maxValue: 0, kind: .fraction)
        #expect(zeroFraction.ticks.count >= 2)
    }
}
