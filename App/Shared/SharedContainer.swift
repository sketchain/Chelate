import Foundation
import PVEKit

/// The App Group (`group.org.sketchain.chelate`) shared by the widget variant of the app and the
/// widget extension. The app keeps its own data in its own container and default Keychain access
/// group (so both variants can replace each other without migration); only what the widget needs
/// is mirrored here:
///
/// - `widget/servers.json`: server configurations (incl. certificate pins and the TFA flag)
/// - `widget/settings.json`: appearance (accent colour)
/// - `widget/cache.json`: the last `NodeSnapshot` per server and node
/// - Keychain items under the service `org.sketchain.chelate.shared` in the App Group access group
///
/// When the app is signed without the App Group `containerURL` is nil; everything here then
/// degrades to no-ops and the settings screen shows a hint.
enum SharedContainer {
    static let groupID = "group.org.sketchain.chelate"

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static var isAvailable: Bool { url != nil }

    /// Mirrored credentials (token secret, remembered password, ticket).
    static let keychain = KeychainStore(service: "org.sketchain.chelate.shared", accessGroup: groupID)

    struct Settings: Codable, Hashable, Sendable {
        var accent: AccentPreset = .orange
    }

    // MARK: Files

    private static func fileURL(_ name: String) -> URL? {
        url?.appendingPathComponent("widget", isDirectory: true).appendingPathComponent(name)
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let file = fileURL(name), let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    @discardableResult
    private static func write<T: Encodable>(_ value: T, _ name: String) -> Bool {
        guard let file = fileURL(name) else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    // MARK: Servers

    static func loadServers() -> [ServerConfig] {
        read([ServerConfig].self, "servers.json") ?? []
    }

    @discardableResult
    static func saveServers(_ servers: [ServerConfig]) -> Bool {
        write(servers, "servers.json")
    }

    // MARK: Settings

    static func loadSettings() -> Settings {
        read(Settings.self, "settings.json") ?? Settings()
    }

    @discardableResult
    static func saveSettings(_ settings: Settings) -> Bool {
        write(settings, "settings.json")
    }

    // MARK: Snapshot cache

    /// Serialises read-modify-write of the cache inside one process.
    private static let cacheLock = NSLock()

    static func loadCache() -> [String: NodeSnapshot] {
        read([String: NodeSnapshot].self, "cache.json") ?? [:]
    }

    static func cachedSnapshot(server: UUID, node: String) -> NodeSnapshot? {
        loadCache()[NodeSnapshot.cacheKey(server: server, node: node)]
    }

    /// Node names known for a server (from cached snapshots), sorted.
    static func knownNodes(server: UUID) -> [String] {
        loadCache().values.filter { $0.serverID == server }.map(\.node).sorted()
    }

    static func store(_ snapshots: [NodeSnapshot]) {
        guard !snapshots.isEmpty else { return }
        cacheLock.withLock {
            var cache = loadCache()
            for snapshot in snapshots {
                cache[snapshot.cacheKey] = snapshot
            }
            write(cache, "cache.json")
        }
    }

    /// Drops cached snapshots of servers that no longer exist.
    static func pruneCache(keeping servers: Set<UUID>) {
        cacheLock.withLock {
            let cache = loadCache()
            let kept = cache.filter { servers.contains($0.value.serverID) }
            if kept.count != cache.count { write(kept, "cache.json") }
        }
    }
}
