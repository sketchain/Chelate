import Foundation
import PVEKit
#if CHELATE_WIDGETS
import WidgetKit
#endif

/// Keeps the App Group copy the widget reads in sync (widget variant only, `CHELATE_WIDGETS`).
/// In the standard variant every call is a no-op, so call sites need no conditional compilation.
///
/// Mirrored: server configurations (incl. pins and the TFA flag), credentials (Keychain, App Group
/// access group), the accent colour and the snapshot cache. Synced on launch and whenever one of
/// them changes; Settings › 数据 › 重新同步小组件数据 runs a full sync by hand.
enum WidgetMirror {
    /// Whether this build contains the widget extension.
    static var isWidgetVariant: Bool {
        #if CHELATE_WIDGETS
        return true
        #else
        return false
        #endif
    }

    /// The widget variant is running with a usable App Group container.
    static var isAvailable: Bool {
        #if CHELATE_WIDGETS
        return SharedContainer.isAvailable
        #else
        return false
        #endif
    }

    private static var isActive: Bool { isAvailable && !DemoMode.isEnabled }

    /// Full sync: configurations, credentials, settings; drops data of deleted servers.
    @discardableResult
    static func syncAll(servers: [ServerConfig], keychain: KeychainStore, accent: AccentPreset) -> Bool {
        #if CHELATE_WIDGETS
        guard isActive else { return false }
        let shared = SharedContainer.keychain
        let previous = SharedContainer.loadServers()
        var ok = SharedContainer.saveServers(servers)
        for server in servers {
            syncCredentials(for: server, keychain: keychain)
        }
        let current = Set(servers.map(\.id))
        for removed in previous where !current.contains(removed.id) {
            shared.removeAll(for: removed.id)
        }
        SharedContainer.pruneCache(keeping: current)
        ok = SharedContainer.saveSettings(SharedContainer.Settings(accent: accent)) && ok
        AppLog.shared.log(.widget, "mirrored \(servers.count) server(s) to the App Group")
        return ok
        #else
        return false
        #endif
    }

    /// Copies one server's credentials (token secret, remembered password, ticket).
    static func syncCredentials(for server: ServerConfig, keychain: KeychainStore) {
        #if CHELATE_WIDGETS
        guard isActive else { return }
        let shared = SharedContainer.keychain
        switch server.authMethod {
        case .apiToken:
            shared.set(keychain.string(for: server.id, .tokenSecret), for: server.id, .tokenSecret)
            shared.set(nil, for: server.id, .password)
            shared.set(nil, for: server.id, .ticket)
        case .password:
            shared.set(nil, for: server.id, .tokenSecret)
            shared.set(server.rememberPassword ? keychain.string(for: server.id, .password) : nil, for: server.id, .password)
            shared.setTicket(keychain.ticket(for: server.id), for: server.id)
        }
        #endif
    }

    /// Mirrors a ticket change right away (called from the auth hooks).
    static func syncTicket(_ ticket: PVETicket?, for server: UUID) {
        #if CHELATE_WIDGETS
        guard isActive else { return }
        if let ticket {
            SharedContainer.keychain.setTicket(ticket, for: server)
        }
        // A cleared app ticket (logout, 401) does not clear the widget's: it may still hold a
        // valid one it renewed itself. Logout clears it explicitly.
        #endif
    }

    static func clearTicket(for server: UUID) {
        #if CHELATE_WIDGETS
        guard isActive else { return }
        SharedContainer.keychain.setTicket(nil, for: server)
        SharedContainer.keychain.set(nil, for: server, .password)
        #endif
    }

    static func syncAccent(_ accent: AccentPreset) {
        #if CHELATE_WIDGETS
        guard isActive else { return }
        SharedContainer.saveSettings(SharedContainer.Settings(accent: accent))
        reloadWidgets(force: true)
        #endif
    }

    /// Stores fresh `/cluster/resources` data for the widgets and asks WidgetKit to reload
    /// (at most once a minute; a forced reload ignores that).
    static func store(resources: [ClusterResource], server: ServerConfig) {
        #if CHELATE_WIDGETS
        guard isActive, !resources.isEmpty else { return }
        SharedContainer.store(NodeSnapshot.make(from: resources, serverID: server.id, serverName: server.displayName))
        reloadWidgets(force: false)
        #endif
    }

    @MainActor private static var lastReload: Date?

    static func reloadWidgets(force: Bool) {
        #if CHELATE_WIDGETS
        Task { @MainActor in
            if !force, let last = lastReload, Date().timeIntervalSince(last) < 60 { return }
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }
}
