import Foundation
import PVEKit
import Testing
@testable import Chelate

@Suite("App model")
@MainActor
struct AppModelTests {
    func temporaryStore() -> ServerStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("servers.json")
        return ServerStore(fileURL: url)
    }

    @Test func serverConfigRoundTripAndTolerantDecoding() throws {
        var config = ServerConfig()
        config.name = "Lab"
        config.host = "10.0.0.2"
        config.pinnedFingerprint = CertificateFingerprint(bytes: Array(repeating: 0xAB, count: 32))
        let data = try JSONEncoder().encode([config])
        let decoded = try JSONDecoder().decode([ServerConfig].self, from: data)
        #expect(decoded == [config])

        // Older / partial records still decode with defaults.
        let partial = #"[{"id":"7C0A3C9E-2F7B-4D7A-9C1F-5B3B2C1D0E9F","host":"pve.local"}]"#
        let legacy = try JSONDecoder().decode([ServerConfig].self, from: Data(partial.utf8))
        #expect(legacy[0].port == 8006)
        #expect(legacy[0].realm == "pam")
        #expect(legacy[0].authMethod == .password)
        #expect(legacy[0].displayName == "pve.local")
    }

    @Test func storePersistsServers() {
        let store = temporaryStore()
        var config = ServerConfig()
        config.host = "pve.example"
        store.save([config])
        #expect(store.load().map(\.host) == ["pve.example"])
    }

    @Test func addEditDelete() {
        let store = temporaryStore()
        let model = AppModel(store: store)
        #expect(model.servers.isEmpty)

        var config = ServerConfig()
        config.host = "pve1.lan"
        model.save(config, tokenSecret: nil)
        #expect(model.servers.count == 1)
        #expect(model.selection == .overview(config.id))

        config.pinnedFingerprint = CertificateFingerprint(bytes: Array(repeating: 1, count: 32))
        model.save(config, tokenSecret: nil)
        // Changing the address drops the pin.
        config.host = "pve2.lan"
        model.save(config, tokenSecret: nil)
        #expect(model.servers[0].host == "pve2.lan")
        #expect(model.servers[0].pinnedFingerprint == nil)

        model.delete(config.id)
        #expect(model.servers.isEmpty)
        #expect(model.selection == nil)
        #expect(AppModel(store: store).servers.isEmpty)
    }

    @Test func keychainRoundTrip() {
        let keychain = KeychainStore(service: "org.sketchain.chelate.tests")
        let id = UUID()
        keychain.set("secret-1", for: id, .tokenSecret)
        #expect(keychain.string(for: id, .tokenSecret) == "secret-1")
        keychain.set("secret-2", for: id, .tokenSecret)
        #expect(keychain.string(for: id, .tokenSecret) == "secret-2")

        let ticket = PVETicket(username: "root@pam", ticket: "PVE:root@pam:6921A3F0::sig", csrfToken: "c", issuedAt: Date(timeIntervalSince1970: 0x6921A3F0))
        keychain.setTicket(ticket, for: id)
        #expect(keychain.ticket(for: id) == ticket)

        keychain.removeAll(for: id)
        #expect(keychain.string(for: id, .tokenSecret) == nil)
        #expect(keychain.ticket(for: id) == nil)
    }
}

@Suite("Presentation")
struct PresentationTests {
    @Test func errorMessagesAreHumanReadable() {
        #expect(ErrorText.message(for: PVEError.network(.cannotConnect)).contains("8006"))
        #expect(ErrorText.message(for: PVEError.forbidden(message: nil)) == "没有权限执行此操作。")
        let mismatch = PVEError.certificate(.fingerprintMismatch(
            expected: CertificateFingerprint(bytes: Array(repeating: 1, count: 32)),
            presented: CertificateInfo(fingerprint: CertificateFingerprint(bytes: Array(repeating: 2, count: 32)), subjectSummary: nil, host: "pve")
        ))
        #expect(ErrorText.message(for: mismatch).contains("警告"))
        #expect(ErrorText.message(for: URLError(.timedOut)).contains("超时"))
        #expect(ErrorText.message(for: PVEError.http(status: 596, message: nil)).contains("596") == false)
    }

    @Test func buildInfoSummaryFormat() {
        let parts = BuildInfo.summary.components(separatedBy: " · ")
        #expect(parts.count == 3)
        #expect(parts[0].contains("("))
    }

    @Test func mimeTypes() {
        #expect(BundleSchemeHandler.mimeType(for: "js").hasPrefix("text/javascript"))
        #expect(BundleSchemeHandler.mimeType(for: "html").hasPrefix("text/html"))
    }

    @Test func bundledNoVNC() throws {
        let root = try #require(Bundle(for: BundleSchemeHandler.self).url(forResource: "VNCWeb", withExtension: nil))
        for path in ["index.html", "bridge.js", "noVNC/core/rfb.js", "noVNC/vendor/pako/lib/zlib/inflate.js", "noVNC/LICENSE.txt"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "missing \(path)")
        }
    }

    @Test func byteFormattingUsesBinaryUnits() {
        #expect(Format.bytes(0) == "0")
        #expect(Format.bytes(13_421_772_800) == "12.5 GiB")
        #expect(Format.rate(0) == "0")
        #expect(Format.rate(1536) == "1.50 KiB/s")
        #expect(Format.bytes(nil) == "–")
    }

    @Test func taskProgressFromLog() {
        let log = [
            TaskLogLine(n: 1, t: "downloading https://example.com/x.iso"),
            TaskLogLine(n: 2, t: "197.66 MiB of 790.63 MiB (25.00%)"),
            TaskLogLine(n: 3, t: "395.31 MiB of 790.63 MiB (50.00%)"),
        ]
        #expect(TaskProgress.fraction(in: log) == 0.5)
        #expect(TaskProgress.fraction(in: [TaskLogLine(n: 1, t: "TASK OK")]) == nil)
        #expect(TaskProgress.fraction(in: "bogus (250%)") == nil)
    }

    @Test func storageContentNames() {
        #expect(Names.storageContent("iso") == "ISO 镜像")
        #expect(Names.storageContent("vztmpl") == "CT 模板")
        #expect(Names.storageContent("other") == "other")
    }

    @Test func taskTypeNames() {
        #expect(Names.taskType("qmstart") == "启动")
        #expect(Names.taskType("custom") == "custom")
        #expect(Names.status(nil) == "未知")
    }
}
