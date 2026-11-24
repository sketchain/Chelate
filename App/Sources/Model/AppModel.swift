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
    case about
}

@MainActor
@Observable
final class AppModel {
    private(set) var servers: [ServerConfig]
    var selection: SidebarItem?
    /// Cache only; not observed so creating a connection during a view update is harmless.
    @ObservationIgnored private var connections: [UUID: ServerConnection] = [:]

    let keychain = KeychainStore()
    private let store: ServerStore

    init(store: ServerStore = ServerStore()) {
        if DemoMode.isEnabled {
            // Demo: one fixture server, persisted only in a throw-away file.
            let demoStore = ServerStore(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("chelate-demo-\(UUID().uuidString)")
                .appendingPathComponent("servers.json"))
            self.store = demoStore
            servers = [ServerConfig.demo]
            selection = .overview(ServerConfig.demo.id)
            return
        }
        self.store = store
        servers = store.load()
        if let first = servers.first {
            selection = .overview(first.id)
        }
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

    /// Adds or updates a server. `secret` is the API token secret (nil = keep).
    func save(_ config: ServerConfig, tokenSecret: String?) {
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
            selection = .overview(config.id)
        }
        store.save(servers)
    }

    func delete(_ id: UUID) {
        servers.removeAll { $0.id == id }
        connections[id] = nil
        keychain.removeAll(for: id)
        store.save(servers)
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
    }

    /// Called by connections when they change their own config (pin, remember flag).
    private func persist(_ config: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[index] = config
        store.save(servers)
    }
}
