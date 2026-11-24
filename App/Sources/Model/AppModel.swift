import Foundation
import Observation
import PVEKit

/// Navigation targets inside a server.
enum Route: Hashable {
    case node(String)
    case guest(GuestRef)
    case config(GuestRef)
    case snapshots(GuestRef)
    case nodeCharts(String)
    case guestCharts(GuestRef)
    case taskLog(node: String, upid: String)
    case console(ConsoleTarget)
    case vnc(GuestRef)
    case tasks(node: String?, vmid: Int?)
    case storage(node: String, storage: String)
}

enum SidebarItem: Hashable {
    case overview(UUID)
    case tasks(UUID)
    case settings
}

/// Navigation inside Settings.
enum SettingsRoute: Hashable {
    case server(UUID)
    case about
    case widgetGallery
}

@MainActor
@Observable
final class AppModel {
    private(set) var servers: [ServerConfig]
    /// nil on launch: iPhone starts on the home screen; on iPad `RootView` selects the first server.
    var selection: SidebarItem?
    /// A `chelate://` link waiting to be applied by the server's navigation stack.
    var pendingDeepLink: DeepLink?
    let settings: AppSettings
    /// Cache only; not observed so creating a connection during a view update is harmless.
    @ObservationIgnored private var connections: [UUID: ServerConnection] = [:]

    let keychain = KeychainStore()
    private let store: ServerStore

    init(store: ServerStore = ServerStore(), settings: AppSettings? = nil) {
        let settings = settings ?? AppSettings()
        self.settings = settings
        if DemoMode.isEnabled {
            // Demo: one fixture server, persisted only in a throw-away file.
            let demoStore = ServerStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("chelate-demo-\(UUID().uuidString)")
                .appendingPathComponent("servers.json"))
            self.store = demoStore
            servers = [ServerConfig.demo]
            return
        }
        self.store = store
        servers = store.load()
        settings.onAccentChange = { accent in WidgetMirror.syncAccent(accent) }
        syncWidgets()
        AppLog.shared.log(.app, "launch \(BuildInfo.summary), \(servers.count) server(s)")
    }

    /// Mirrors configuration and credentials for the widget (no-op in the standard variant).
    @discardableResult
    func syncWidgets() -> Bool {
        let ok = WidgetMirror.syncAll(servers: servers, keychain: keychain, accent: settings.accent)
        if ok { WidgetMirror.reloadWidgets(force: true) }
        return ok
    }

    /// Opens a `chelate://` link (widgets).
    func open(_ url: URL) {
        guard let link = DeepLink(url: url), server(link.server) != nil else {
            AppLog.shared.log(.app, "ignored link \(url.host ?? "?")")
            return
        }
        selection = .overview(link.server)
        pendingDeepLink = link
    }

    func server(_ id: UUID) -> ServerConfig? {
        servers.first { $0.id == id }
    }

    func connection(for id: UUID) -> ServerConnection? {
        if let existing = connections[id] { return existing }
        guard let config = server(id) else { return nil }
        let connection = ServerConnection(config: config, keychain: keychain) { [weak self] updated in
            self?.persist(updated)
        }
        connections[id] = connection
        return connection
    }

    /// Adds or updates a server. `secret` is the API token secret (nil = keep). A new server is
    /// selected (opened) when `select` is true.
    func save(_ config: ServerConfig, tokenSecret: String?, select: Bool = true) {
        if let secret = tokenSecret, !secret.isEmpty {
            keychain.set(secret, for: config.id, .tokenSecret)
        }
        if config.authMethod == .apiToken {
            keychain.set(nil, for: config.id, .password)
            keychain.setTicket(nil, for: config.id)
        } else {
            keychain.set(nil, for: config.id, .tokenSecret)
        }
        if let index = servers.firstIndex(where: { $0.id == config.id }) {
            let old = servers[index]
            var updated = config
            // A changed address invalidates the pinned certificate and any ticket.
            if old.endpoint != config.endpoint {
                updated.pinnedFingerprint = nil
                keychain.setTicket(nil, for: config.id)
            }
            if old.account != config.account || old.authMethod != config.authMethod {
                keychain.setTicket(nil, for: config.id)
            }
            servers[index] = updated
            connections[config.id]?.update(config: updated)
            if old.endpoint != config.endpoint || old.authMethod != config.authMethod || tokenSecret?.isEmpty == false {
                connections[config.id] = nil
            }
        } else {
            servers.append(config)
            if select { selection = .overview(config.id) }
        }
        store.save(servers)
        syncWidgets()
    }

    /// Clears the pinned certificate; the next connection asks for trust again.
    func forgetCertificate(_ id: UUID) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[index].pinnedFingerprint = nil
        connections[id]?.update(config: servers[index])
        store.save(servers)
        syncWidgets()
        AppLog.shared.log(.auth, "certificate pin cleared for \(id.uuidString.prefix(8))")
    }

    func delete(_ id: UUID) {
        servers.removeAll { $0.id == id }
        connections[id] = nil
        keychain.removeAll(for: id)
        store.save(servers)
        syncWidgets()
        switch selection {
        case .overview(id)?, .tasks(id)?:
            selection = servers.first.map { .overview($0.id) }
        default:
            break
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        store.save(servers)
        syncWidgets()
    }

    /// Called by connections when they change their own config (pin, remember flag).
    private func persist(_ config: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[index] = config
        store.save(servers)
        syncWidgets()
    }
}
