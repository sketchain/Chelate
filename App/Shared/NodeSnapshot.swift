import Foundation
import PVEKit

/// What a node widget shows: node load and its guests at one point in time. Written to the App
/// Group cache by the app (from `/cluster/resources`) and by the widget (from its own requests).
struct NodeSnapshot: Codable, Hashable, Sendable {
    struct Guest: Codable, Hashable, Sendable, Identifiable {
        var vmid: Int
        var name: String
        var type: GuestType
        var status: String
        var cpu: Double
        var template: Bool = false

        var id: Int { vmid }
        var isRunning: Bool { status == "running" }
        var ref: GuestRef { GuestRef(node: "", type: type, vmid: vmid) }
    }

    var serverID: UUID
    var serverName: String
    var node: String
    var online: Bool
    /// 0…1
    var cpu: Double
    var memoryUsed: Double
    var memoryTotal: Double
    var guests: [Guest]
    var fetchedAt: Date

    var memory: Double { memoryTotal > 0 ? memoryUsed / memoryTotal : 0 }

    var runningGuests: [Guest] { guests.filter(\.isRunning) }

    /// Running guests by CPU, busiest first.
    var busiestGuests: [Guest] {
        runningGuests.sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.vmid < $1.vmid }
    }

    /// Stopped guests (templates are not counted).
    var stoppedCount: Int { guests.filter { !$0.isRunning && !$0.template }.count }

    var cacheKey: String { Self.cacheKey(server: serverID, node: node) }

    static func cacheKey(server: UUID, node: String) -> String { "\(server.uuidString)/\(node)" }

    func guestLink(_ guest: Guest) -> URL {
        DeepLink.guest(server: serverID, guest: GuestRef(node: node, type: guest.type, vmid: guest.vmid)).url
    }

    var nodeLink: URL { DeepLink.node(server: serverID, node: node).url }
}

extension NodeSnapshot {
    /// Builds snapshots for every node from `/cluster/resources` (app side).
    static func make(from resources: [ClusterResource], serverID: UUID, serverName: String, at date: Date = Date()) -> [NodeSnapshot] {
        NodeGroup.group(resources).map { group in
            let node = group.nodeResource
            return NodeSnapshot(
                serverID: serverID,
                serverName: serverName,
                node: group.node,
                online: node?.isOnline ?? false,
                cpu: node?.cpu ?? 0,
                memoryUsed: node?.mem ?? 0,
                memoryTotal: node?.maxmem ?? 0,
                guests: group.guests.compactMap { resource in
                    guard let ref = resource.guestRef else { return nil }
                    return Guest(
                        vmid: ref.vmid,
                        name: resource.displayName,
                        type: ref.type,
                        status: resource.status ?? "unknown",
                        cpu: resource.cpu ?? 0,
                        template: resource.template
                    )
                },
                fetchedAt: date
            )
        }
    }

    /// Fixture used by demo mode, the widget gallery and widget previews.
    static func demo(serverID: UUID = UUID(uuidString: "00000000-0000-4000-8000-00000000DE70")!, fetchedAt: Date = Date().addingTimeInterval(-120)) -> NodeSnapshot {
        NodeSnapshot(
            serverID: serverID,
            serverName: "Homelab",
            node: "pve",
            online: true,
            cpu: 0.23,
            memoryUsed: 41.2 * 1_073_741_824,
            memoryTotal: 64 * 1_073_741_824,
            guests: [
                Guest(vmid: 100, name: "debian-web", type: .qemu, status: "running", cpu: 0.18),
                Guest(vmid: 101, name: "win11", type: .qemu, status: "running", cpu: 0.42),
                Guest(vmid: 102, name: "home-assistant", type: .qemu, status: "running", cpu: 0.05),
                Guest(vmid: 200, name: "pihole", type: .lxc, status: "running", cpu: 0.01),
                Guest(vmid: 201, name: "jellyfin", type: .lxc, status: "running", cpu: 0.27),
                Guest(vmid: 103, name: "test-vm", type: .qemu, status: "stopped", cpu: 0),
                Guest(vmid: 202, name: "backup", type: .lxc, status: "stopped", cpu: 0),
                Guest(vmid: 9000, name: "debian-template", type: .qemu, status: "stopped", cpu: 0, template: true),
            ],
            fetchedAt: fetchedAt
        )
    }
}
