import Foundation

public enum GuestType: String, Sendable, Hashable, Codable, CaseIterable {
    case qemu
    case lxc
}

/// One entry of `GET /cluster/resources`.
public struct ClusterResource: Decodable, Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case node
        case qemu
        case lxc
        case storage
        case pool
        case sdn
        case other(String)

        init(raw: String) {
            switch raw {
            case "node": self = .node
            case "qemu": self = .qemu
            case "lxc": self = .lxc
            case "storage": self = .storage
            case "pool": self = .pool
            case "sdn": self = .sdn
            default: self = .other(raw)
            }
        }

        public var guestType: GuestType? {
            switch self {
            case .qemu: return .qemu
            case .lxc: return .lxc
            default: return nil
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var node: String?
    public var status: String?
    public var name: String?
    public var vmid: Int?
    public var cpu: Double?
    public var maxcpu: Double?
    public var mem: Double?
    public var maxmem: Double?
    public var disk: Double?
    public var maxdisk: Double?
    public var uptime: Int?
    public var template: Bool
    public var storage: String?
    public var plugintype: String?
    public var shared: Bool
    public var content: String?
    public var tags: [String]
    public var lock: String?
    public var hastate: String?
    public var pool: String?

    enum CodingKeys: String, CodingKey {
        case id, type, node, status, name, vmid, cpu, maxcpu, mem, maxmem, disk, maxdisk, uptime
        case template, storage, plugintype, shared, content, tags, lock, hastate, pool
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = Kind(raw: try c.decode(String.self, forKey: .type))
        node = c.flexibleString(.node)
        status = c.flexibleString(.status)
        name = c.flexibleString(.name)
        vmid = c.flexibleInt(.vmid)
        cpu = c.flexibleDouble(.cpu)
        maxcpu = c.flexibleDouble(.maxcpu)
        mem = c.flexibleDouble(.mem)
        maxmem = c.flexibleDouble(.maxmem)
        disk = c.flexibleDouble(.disk)
        maxdisk = c.flexibleDouble(.maxdisk)
        uptime = c.flexibleInt(.uptime)
        template = c.flexibleBool(.template) ?? false
        storage = c.flexibleString(.storage)
        plugintype = c.flexibleString(.plugintype)
        shared = c.flexibleBool(.shared) ?? false
        content = c.flexibleString(.content)
        let rawTags = c.flexibleString(.tags) ?? ""
        tags = rawTags.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).map(String.init)
        lock = c.flexibleString(.lock)
        hastate = c.flexibleString(.hastate)
        pool = c.flexibleString(.pool)
    }

    public init(
        id: String, kind: Kind, node: String?, status: String?, name: String? = nil, vmid: Int? = nil,
        cpu: Double? = nil, maxcpu: Double? = nil, mem: Double? = nil, maxmem: Double? = nil,
        disk: Double? = nil, maxdisk: Double? = nil, uptime: Int? = nil, template: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.node = node
        self.status = status
        self.name = name
        self.vmid = vmid
        self.cpu = cpu
        self.maxcpu = maxcpu
        self.mem = mem
        self.maxmem = maxmem
        self.disk = disk
        self.maxdisk = maxdisk
        self.uptime = uptime
        self.template = template
        storage = nil
        plugintype = nil
        shared = false
        content = nil
        tags = []
        lock = nil
        hastate = nil
        pool = nil
    }

    public var isRunning: Bool { status == "running" }
    public var isOnline: Bool { status == "online" || status == "running" || status == "available" }

    /// Display name: guest name, storage name or node name.
    public var displayName: String {
        switch kind {
        case .qemu, .lxc:
            return name ?? vmid.map(String.init) ?? id
        case .storage:
            return storage ?? id
        case .node:
            return node ?? id
        default:
            return name ?? id
        }
    }

    public var memoryFraction: Double? {
        guard let mem, let maxmem, maxmem > 0 else { return nil }
        return mem / maxmem
    }

    public var diskFraction: Double? {
        guard let disk, let maxdisk, maxdisk > 0 else { return nil }
        return disk / maxdisk
    }

    public var guestRef: GuestRef? {
        guard let type = kind.guestType, let node, let vmid else { return nil }
        return GuestRef(node: node, type: type, vmid: vmid)
    }
}

/// Identifies a guest on a node.
public struct GuestRef: Sendable, Hashable, Codable {
    public var node: String
    public var type: GuestType
    public var vmid: Int

    public init(node: String, type: GuestType, vmid: Int) {
        self.node = node
        self.type = type
        self.vmid = vmid
    }

    /// `/nodes/<node>/<qemu|lxc>/<vmid>`
    public var basePath: String {
        PathBuilder.path("nodes", node, type.rawValue, String(vmid))
    }

    /// ACL path for permission checks.
    public var aclPath: String { "/vms/\(vmid)" }
}

/// Resources grouped for the overview screen.
public struct NodeGroup: Sendable, Hashable, Identifiable {
    public var id: String { node }
    public var node: String
    public var nodeResource: ClusterResource?
    public var guests: [ClusterResource]
    public var storages: [ClusterResource]

    /// Groups `/cluster/resources` by node; guests sorted by VMID, storages by name.
    public static func group(_ resources: [ClusterResource]) -> [NodeGroup] {
        var groups: [String: NodeGroup] = [:]
        for resource in resources {
            guard let node = resource.node else { continue }
            var group = groups[node] ?? NodeGroup(node: node, nodeResource: nil, guests: [], storages: [])
            switch resource.kind {
            case .node: group.nodeResource = resource
            case .qemu, .lxc: group.guests.append(resource)
            case .storage: group.storages.append(resource)
            default: break
            }
            groups[node] = group
        }
        return groups.values
            .map { group in
                var group = group
                group.guests.sort { ($0.vmid ?? 0) < ($1.vmid ?? 0) }
                group.storages.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
                return group
            }
            .sorted { $0.node.localizedStandardCompare($1.node) == .orderedAscending }
    }
}
