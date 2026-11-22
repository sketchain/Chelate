import Foundation
import PVEKit
import Security

/// Stores server configurations as JSON in Application Support.
struct ServerStore {
    var fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("servers.json")
        }
    }

    func load() -> [ServerConfig] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([ServerConfig].self, from: data)) ?? []
    }

    func save(_ servers: [ServerConfig]) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(servers).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            assertionFailure("Saving servers failed: \(error)")
        }
    }
}

/// Generic-password Keychain items, one per server and kind.
struct KeychainStore: Sendable {
    enum Item: String, Sendable {
        case tokenSecret
        case password
        case ticket
    }

    var service: String = "org.sketchain.chelate"

    private func account(_ server: UUID, _ item: Item) -> String {
        "\(server.uuidString).\(item.rawValue)"
    }

    private func baseQuery(_ server: UUID, _ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(server, item),
        ]
    }

    func string(for server: UUID, _ item: Item) -> String? {
        var query = baseQuery(server, item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String?, for server: UUID, _ item: Item) -> Bool {
        let query = baseQuery(server, item)
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert.merge(attributes) { _, new in new }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    func removeAll(for server: UUID) {
        for item in [Item.tokenSecret, .password, .ticket] {
            set(nil, for: server, item)
        }
    }

    // Ticket persistence (JSON encoded PVETicket).

    func ticket(for server: UUID) -> PVETicket? {
        guard let json = string(for: server, .ticket), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PVETicket.self, from: data)
    }

    func setTicket(_ ticket: PVETicket?, for server: UUID) {
        guard let ticket, let data = try? JSONEncoder().encode(ticket) else {
            set(nil, for: server, .ticket)
            return
        }
        set(String(decoding: data, as: UTF8.self), for: server, .ticket)
    }
}
