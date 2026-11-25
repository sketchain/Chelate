import Foundation
import PVEKit
import Testing
@testable import Chelate

@Suite("Widgets and links")
struct WidgetSupportTests {
    @Test func deepLinkRoundTrip() throws {
        let server = UUID()
        let node = DeepLink.node(server: server, node: "pve 1")
        #expect(node.url.scheme == "chelate")
        #expect(DeepLink(url: node.url) == node)

        let guest = DeepLink.guest(server: server, guest: GuestRef(node: "pve", type: .lxc, vmid: 200))
        #expect(DeepLink(url: guest.url) == guest)

        #expect(DeepLink(url: URL(string: "chelate://guest?server=\(server.uuidString)&node=pve&type=vm&vmid=1")!) == nil)
        #expect(DeepLink(url: URL(string: "https://example.com/node?server=\(server.uuidString)&node=pve")!) == nil)
    }

    @Test func snapshotSummary() {
        let snapshot = NodeSnapshot.demo()
        #expect(snapshot.runningGuests.count == 5)
        #expect(snapshot.stoppedCount == 2, "templates are not counted as stopped")
        #expect(snapshot.busiestGuests.prefix(4).map(\.name) == ["win11", "jellyfin", "debian-web", "home-assistant"])
        #expect(abs(snapshot.memory - 41.2 / 64) < 0.0001)
        #expect(DeepLink(url: snapshot.guestLink(snapshot.guests[0])) == .guest(server: snapshot.serverID, guest: GuestRef(node: "pve", type: .qemu, vmid: 100)))
    }

    @Test func widgetTexts() {
        let now = Date()
        #expect(NodeWidgetText.percent(0.234) == "23%")
        #expect(NodeWidgetText.relative(now.addingTimeInterval(-10), now: now) == "刚刚")
        let offline = NodeWidgetContent(snapshot: .demo(fetchedAt: now.addingTimeInterval(-7200)), state: .offline)
        #expect(NodeWidgetText.footer(offline, now: now).hasPrefix("离线 · "))
        #expect(NodeWidgetText.isDimmed(offline))
        #expect(NodeWidgetText.footer(NodeWidgetContent(snapshot: nil, state: .needsLogin), now: now) == "打开 App 重新登录")
    }

    @Test func accentGradient() {
        #expect(AccentPreset.allCases.count == 5)
        #expect(AccentPreset.orange.gradientEnd == .pink)
        #expect(AccentPreset.pink.gradientEnd == .orange)
    }
}

@Suite("Settings")
@MainActor
struct SettingsTests {
    private func makeDefaults() -> UserDefaults {
        let name = "chelate-tests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test func defaultsAndPersistence() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        #expect(settings.autoRefresh == .seconds10)
        #expect(settings.chartTimeframe == .hour)
        #expect(settings.theme == .system)
        #expect(settings.accent == .orange)
        #expect(settings.faceIDLock == false)
        #expect(settings.confirmDangerousActions == true)

        settings.autoRefresh = .off
        settings.accent = .purple
        settings.chartTimeframe = .week
        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.autoRefresh == .off)
        #expect(reloaded.autoRefresh.interval == nil)
        #expect(reloaded.accent == .purple)
        #expect(reloaded.chartTimeframe == .week)
    }

    @Test func dangerousActionConfirmation() {
        let settings = AppSettings(defaults: makeDefaults())
        #expect(settings.needsConfirmation(.stop))
        #expect(settings.needsConfirmation(.suspend))
        #expect(!settings.needsConfirmation(.start))
        settings.confirmDangerousActions = false
        #expect(!settings.needsConfirmation(.shutdown))
    }

    @Test func launchSelectionAndDeepLinks() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("servers.json")
        var config = ServerConfig()
        config.host = "pve.lan"
        ServerStore(fileURL: url).save([config])
        let model = AppModel(store: ServerStore(fileURL: url), settings: AppSettings(defaults: makeDefaults()))
        #expect(model.selection == nil, "iPhone launches on the home screen")

        model.open(DeepLink.node(server: config.id, node: "pve").url)
        #expect(model.selection == .overview(config.id))
        #expect(model.pendingDeepLink == .node(server: config.id, node: "pve"))

        model.pendingDeepLink = nil
        model.open(DeepLink.node(server: UUID(), node: "pve").url)
        #expect(model.pendingDeepLink == nil, "links to unknown servers are ignored")
    }

    @Test func forgetCertificateAndAddWithoutSelecting() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("servers.json")
        let model = AppModel(store: ServerStore(fileURL: url), settings: AppSettings(defaults: makeDefaults()))
        var config = ServerConfig()
        config.host = "pve.lan"
        config.pinnedFingerprint = CertificateFingerprint(bytes: Array(repeating: 7, count: 32))
        model.save(config, tokenSecret: nil, select: false)
        #expect(model.selection == nil)
        #expect(model.servers[0].pinnedFingerprint != nil)
        model.forgetCertificate(config.id)
        #expect(model.servers[0].pinnedFingerprint == nil)
        #expect(ServerStore(fileURL: url).load()[0].pinnedFingerprint == nil)
    }
}

@Suite("Log")
struct LogTests {
    @Test func exportIsRedacted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = AppLog(directory: directory)
        // Write synchronously through the public API and wait for the queue.
        log.log(.auth, "Cookie: PVEAuthCookie=PVE:root@pam:6921A3F0::c2lnbmF0dXJl")
        log.log(.network, "GET /nodes/pve/status → 200 (5 ms)")
        let text = log.exportText()
        #expect(!text.contains("c2lnbmF0dXJl"))
        #expect(text.contains("GET /nodes/pve/status"))
        log.clear()
    }

    @Test func rotation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let log = AppLog(directory: directory)
        let line = String(repeating: "x", count: 1024)
        for _ in 0..<(AppLog.maxFileSize / 1024 + 20) {
            log.log(.app, line)
        }
        _ = log.exportText() // drains the queue
        #expect(FileManager.default.fileExists(atPath: log.previousFile.path))
        let size = try FileManager.default.attributesOfItem(atPath: log.currentFile.path)[.size] as? Int ?? 0
        #expect(size <= AppLog.maxFileSize + 2048)
        log.clear()
    }
}

@Suite("Chart selection popover")
struct ChartPopoverTests {
    let plot = CGRect(x: 40, y: 0, width: 300, height: 200)
    let size = CGSize(width: 140, height: 50)

    private func frame(ruleX: CGFloat, pointYs: [CGFloat]) -> CGRect {
        let center = SeriesChart.popoverCenter(size: size, plot: plot, ruleX: ruleX, pointYs: pointYs)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    @Test func flipsToTheFarSideOfTheRule() {
        let left = frame(ruleX: 80, pointYs: [150])
        #expect(left.minX > 80, "point on the left → popover right of the rule")
        let right = frame(ruleX: 300, pointYs: [150])
        #expect(right.maxX < 300, "point on the right → popover left of the rule")
    }

    @Test func movesDownWhenThePointIsHigh() {
        #expect(frame(ruleX: 80, pointYs: [150]).minY < 20)
        #expect(frame(ruleX: 80, pointYs: [20]).maxY > 180)
    }

    @Test func staysInsideThePlot() {
        for x in stride(from: plot.minX, through: plot.maxX, by: 10) {
            for y in stride(from: plot.minY, through: plot.maxY, by: 25) {
                let rect = frame(ruleX: x, pointYs: [y])
                #expect(plot.contains(rect), "x \(x), y \(y): \(rect)")
            }
        }
    }
}
