import Foundation

/// `GET /nodes/{node}/{qemu|lxc}/{vmid}/status/current`
public struct GuestStatus: Decodable, Sendable, Hashable {
    public var status: String
    public var qmpstatus: String?
    public var name: String?
    public var vmid: Int?
    public var cpu: Double?
    public var cpus: Double?
    public var mem: Double?
    public var maxmem: Double?
    public var disk: Double?
    public var maxdisk: Double?
    public var swap: Double?
    public var maxswap: Double?
    public var uptime: Int?
    public var netin: Double?
    public var netout: Double?
    public var diskread: Double?
    public var diskwrite: Double?
    public var lock: String?
    public var tags: String?
    public var template: Bool
    public var agent: Bool
    public var haState: String?

    enum CodingKeys: String, CodingKey {
        case status, qmpstatus, name, vmid, cpu, cpus, mem, maxmem, disk, maxdisk, swap, maxswap, uptime
        case netin, netout, diskread, diskwrite, lock, tags, template, agent, ha
    }

    enum HAKeys: String, CodingKey {
        case state, managed
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.flexibleString(.status) ?? "unknown"
        qmpstatus = c.flexibleString(.qmpstatus)
        name = c.flexibleString(.name)
        vmid = c.flexibleInt(.vmid)
        cpu = c.flexibleDouble(.cpu)
        cpus = c.flexibleDouble(.cpus)
        mem = c.flexibleDouble(.mem)
        maxmem = c.flexibleDouble(.maxmem)
        disk = c.flexibleDouble(.disk)
        maxdisk = c.flexibleDouble(.maxdisk)
        swap = c.flexibleDouble(.swap)
        maxswap = c.flexibleDouble(.maxswap)
        uptime = c.flexibleInt(.uptime)
        netin = c.flexibleDouble(.netin)
        netout = c.flexibleDouble(.netout)
        diskread = c.flexibleDouble(.diskread)
        diskwrite = c.flexibleDouble(.diskwrite)
        lock = c.flexibleString(.lock)
        tags = c.flexibleString(.tags)
        template = c.flexibleBool(.template) ?? false
        agent = c.flexibleBool(.agent) ?? false
        if let ha = try? c.nestedContainer(keyedBy: HAKeys.self, forKey: .ha) {
            haState = ha.flexibleString(.state)
        } else {
            haState = nil
        }
    }

    public var isRunning: Bool { status == "running" }
    /// qemu reports `status: running` + `qmpstatus: paused|suspended` for paused guests.
    public var isPaused: Bool {
        guard let qmpstatus else { return false }
        return qmpstatus == "paused" || qmpstatus == "suspended" || qmpstatus == "prelaunch"
    }

    /// The most specific state string.
    public var effectiveState: String {
        if isRunning, let qmpstatus, qmpstatus != "running" { return qmpstatus }
        return status
    }
}

/// `GET /nodes/{node}/status`
public struct NodeStatus: Decodable, Sendable, Hashable {
    public struct Usage: Decodable, Sendable, Hashable {
        public var used: Double?
        public var total: Double?
        public var free: Double?

        enum CodingKeys: String, CodingKey { case used, total, free }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            used = c.flexibleDouble(.used)
            total = c.flexibleDouble(.total)
            free = c.flexibleDouble(.free)
        }

        public var fraction: Double? {
            guard let used, let total, total > 0 else { return nil }
            return used / total
        }
    }

    public struct CPUInfo: Decodable, Sendable, Hashable {
        public var model: String?
        public var cpus: Int?
        public var sockets: Int?
        public var cores: Int?

        enum CodingKeys: String, CodingKey { case model, cpus, sockets, cores }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            model = c.flexibleString(.model)
            cpus = c.flexibleInt(.cpus)
            sockets = c.flexibleInt(.sockets)
            cores = c.flexibleInt(.cores)
        }
    }

    public var cpu: Double?
    public var wait: Double?
    public var uptime: Int?
    public var loadavg: [String]
    public var memory: Usage?
    public var swap: Usage?
    public var rootfs: Usage?
    public var cpuinfo: CPUInfo?
    public var pveversion: String?
    public var kversion: String?

    enum CodingKeys: String, CodingKey {
        case cpu, wait, uptime, loadavg, memory, swap, rootfs, cpuinfo, pveversion, kversion
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpu = c.flexibleDouble(.cpu)
        wait = c.flexibleDouble(.wait)
        uptime = c.flexibleInt(.uptime)
        if let values = try? c.decodeIfPresent([JSONValue].self, forKey: .loadavg) {
            loadavg = values.map(\.displayString)
        } else {
            loadavg = []
        }
        memory = try? c.decodeIfPresent(Usage.self, forKey: .memory)
        swap = try? c.decodeIfPresent(Usage.self, forKey: .swap)
        rootfs = try? c.decodeIfPresent(Usage.self, forKey: .rootfs)
        cpuinfo = try? c.decodeIfPresent(CPUInfo.self, forKey: .cpuinfo)
        pveversion = c.flexibleString(.pveversion)
        kversion = c.flexibleString(.kversion)
    }
}

/// `GET /version`
public struct VersionInfo: Decodable, Sendable, Hashable {
    public var version: String
    public var release: String?
    public var repoid: String?
}

/// Guest configuration (`GET .../config`), kept as an ordered list of key/value strings.
public struct GuestConfig: Decodable, Sendable, Hashable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public var id: String { key }
        public var key: String
        public var value: String
    }

    public var entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    public init(from decoder: any Decoder) throws {
        let raw = try [String: JSONValue](from: decoder)
        entries = raw
            .filter { $0.key != "digest" }
            .map { Entry(key: $0.key, value: $0.value.displayString) }
            .sorted { GuestConfig.order($0.key, $1.key) }
    }

    public subscript(key: String) -> String? {
        entries.first { $0.key == key }?.value
    }

    /// Sorts well known keys first, then device keys (net0, scsi0 ...) naturally.
    static func order(_ lhs: String, _ rhs: String) -> Bool {
        let priority = ["name", "hostname", "description", "ostype", "arch", "cores", "sockets", "cpu", "memory", "swap", "balloon", "boot", "onboot"]
        let li = priority.firstIndex(of: lhs) ?? Int.max
        let ri = priority.firstIndex(of: rhs) ?? Int.max
        if li != ri { return li < ri }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
