import Foundation
import PVEKit

/// `chelate://` URLs opened from widgets:
///
///     chelate://node?server=<uuid>&node=pve
///     chelate://guest?server=<uuid>&node=pve&type=qemu&vmid=100
enum DeepLink: Hashable, Sendable {
    case node(server: UUID, node: String)
    case guest(server: UUID, guest: GuestRef)

    static let scheme = "chelate"

    var server: UUID {
        switch self {
        case .node(let server, _), .guest(let server, _): return server
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .node(let server, let node):
            components.host = "node"
            components.queryItems = [
                URLQueryItem(name: "server", value: server.uuidString),
                URLQueryItem(name: "node", value: node),
            ]
        case .guest(let server, let guest):
            components.host = "guest"
            components.queryItems = [
                URLQueryItem(name: "server", value: server.uuidString),
                URLQueryItem(name: "node", value: guest.node),
                URLQueryItem(name: "type", value: guest.type.rawValue),
                URLQueryItem(name: "vmid", value: String(guest.vmid)),
            ]
        }
        return components.url!
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        guard let server = query["server"].flatMap(UUID.init(uuidString:)),
              let node = query["node"], !node.isEmpty else { return nil }
        switch components.host?.lowercased() {
        case "node":
            self = .node(server: server, node: node)
        case "guest":
            guard let type = query["type"].flatMap(GuestType.init(rawValue:)),
                  let vmid = query["vmid"].flatMap(Int.init) else { return nil }
            self = .guest(server: server, guest: GuestRef(node: node, type: type, vmid: vmid))
        default:
            return nil
        }
    }
}
