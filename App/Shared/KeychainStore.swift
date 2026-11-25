import Foundation
import PVEKit
import Security

/// Generic-password Keychain items, one per server and kind.
struct KeychainStore: Sendable {
    enum Item: String, Sendable {
        case tokenSecret
        case password
        case ticket
    }

    var service: String = "org.sketchain.chelate"
    /// nil: the app's default access group (its own items). The widget variant mirrors items
    /// into the App Group (`SharedContainer.keychain`) under a different service name, so a
    /// lookup without access group can never pick up a mirrored copy by accident.
    var accessGroup: String?

    init(service: String = "org.sketchain.chelate", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func account(_ server: UUID, _ item: Item) -> String {
        "\(server.uuidString).\(item.rawValue)"
    }

    private func baseQuery(_ server: UUID, _ item: Item) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(server, item),
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
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
