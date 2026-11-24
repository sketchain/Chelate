import Foundation

/// One row of `GET /nodes/{node}/{type}/{vmid}/pending`: the current value and, when a change
/// waits for the next restart, the pending value (or a pending delete).
public struct PendingEntry: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var value: String?
    public var pending: String?
    public var delete: Bool

    public init(key: String, value: String?, pending: String? = nil, delete: Bool = false) {
        self.key = key
        self.value = value
        self.pending = pending
        self.delete = delete
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        key = c.flexibleString(AnyCodingKey("key")) ?? ""
        value = c.flexibleString(AnyCodingKey("value"))
        pending = c.flexibleString(AnyCodingKey("pending"))
        // `delete`: 1 = pending delete, 2 = forced delete.
        delete = (c.flexibleInt(AnyCodingKey("delete")) ?? 0) > 0
    }

    /// A change that applies after the next restart.
    public var hasPendingChange: Bool { pending != nil || delete }

    /// The value after the restart.
    public var effective: String? { delete ? nil : (pending ?? value) }
}

/// Sizes as written in disk configs: `32G`, `512M`, `1.5T`, `4096` (bytes) …
public enum DiskSize {
    static let units: [Character: Double] = ["K": 1024, "M": 1024 * 1024, "G": 1024 * 1024 * 1024, "T": 1024 * 1024 * 1024 * 1024]

    public static func bytes(_ text: String) -> Double? {
        var string = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard !string.isEmpty else { return nil }
        var factor = 1.0
        if let last = string.last, let unit = units[last] {
            factor = unit
            string.removeLast()
        } else if string.hasSuffix("B") {
            string.removeLast()
        }
        guard let value = Double(string), value >= 0 else { return nil }
        return value * factor
    }

    /// `size=` of a disk property string.
    public static func bytes(ofDisk config: String) -> Double? {
        PropertyString.parse(config)["size"].flatMap { bytes($0) }
    }

    /// GiB with up to two decimals, as the size parameter (`34G`, `10.5G`).
    public static func gibParameter(_ gib: Double) -> String {
        let rounded = (gib * 100).rounded() / 100
        if rounded == rounded.rounded() { return "\(Int(rounded))G" }
        return "\(rounded)G"
    }
}

/// A resizable disk of a guest (VM: ide/sata/scsi/virtio disks without `media=cdrom`;
/// CT: `rootfs`, `mpN` volumes).
public struct GuestDisk: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var config: String
    public var size: Double?
    /// `local-zfs:vm-100-disk-0` (first field of the property string).
    public var volume: String
    public var pendingConfig: String?

    public init(key: String, config: String, pendingConfig: String? = nil) {
        self.key = key
        self.config = config
        self.pendingConfig = pendingConfig
        size = DiskSize.bytes(ofDisk: config)
        volume = config.split(separator: ",").first.map(String.init) ?? config
    }

    public var storage: String? {
        guard let colon = volume.firstIndex(of: ":") else { return nil }
        return String(volume[..<colon])
    }

    static func isVMDiskKey(_ key: String) -> Bool {
        key.range(of: #"^(ide|sata|scsi|virtio)\d+$"#, options: .regularExpression) != nil
    }

    static func isCTDiskKey(_ key: String) -> Bool {
        key == "rootfs" || key.range(of: #"^mp\d+$"#, options: .regularExpression) != nil
    }

    /// Whether a config entry is a resizable disk of the guest type.
    public static func isDisk(key: String, value: String, type: GuestType) -> Bool {
        switch type {
        case .qemu:
            guard isVMDiskKey(key) else { return false }
            let props = PropertyString.parse(value)
            if props["media"] == "cdrom" { return false }
            let volume = value.split(separator: ",").first.map(String.init) ?? ""
            return volume != "none" && !volume.isEmpty
        case .lxc:
            return isCTDiskKey(key)
        }
    }
}

/// Request for 「Resize disk」. The WebUI's dialog sends an increment (`+NG`); here either an
/// increment or a target size is accepted, both only growing the disk.
public struct DiskResize: Sendable, Hashable {
    public enum Input: Sendable, Hashable {
        case increment(gib: Double)
        case target(gib: Double)
    }

    public var disk: GuestDisk
    public var input: Input

    public init(disk: GuestDisk, input: Input) {
        self.disk = disk
        self.input = input
    }

    static let gib = 1024.0 * 1024 * 1024

    /// Size after the resize in bytes (nil when it would not grow the disk).
    public var newSize: Double? {
        let current = disk.size ?? 0
        switch input {
        case .increment(let gib):
            guard gib > 0 else { return nil }
            return current + gib * Self.gib
        case .target(let gib):
            let target = gib * Self.gib
            guard target > current else { return nil }
            return target
        }
    }

    public var isValid: Bool { newSize != nil }

    /// The `size` parameter: `+10G` or `50G`.
    public var sizeParameter: String? {
        guard isValid else { return nil }
        switch input {
        case .increment(let gib): return "+" + DiskSize.gibParameter(gib)
        case .target(let gib): return DiskSize.gibParameter(gib)
        }
    }

    public func qemuRequest(_ guest: GuestRef) -> PVEAPI.PutNodesQemuResize? {
        guard let size = sizeParameter, let disk = PVEAPI.PutNodesQemuResize.Disk(rawValue: disk.key) else { return nil }
        return PVEAPI.PutNodesQemuResize(node: guest.node, vmid: guest.vmid, disk: disk, size: size)
    }

    public func lxcRequest(_ guest: GuestRef) -> PVEAPI.PutNodesLxcResize? {
        guard let size = sizeParameter, let disk = PVEAPI.PutNodesLxcResize.Disk(rawValue: disk.key) else { return nil }
        return PVEAPI.PutNodesLxcResize(node: guest.node, vmid: guest.vmid, disk: disk, size: size)
    }
}

/// Processor, memory and disks of a guest from its pending config.
public struct GuestHardware: Sendable, Hashable {
    public var type: GuestType
    public var entries: [String: PendingEntry]

    public init(type: GuestType, pending: [PendingEntry]) {
        self.type = type
        entries = Dictionary(pending.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func int(_ key: String, pending: Bool) -> Int? {
        guard let entry = entries[key] else { return nil }
        let text = pending ? entry.effective : entry.value
        return text.flatMap { value in
            // `memory` is `[current=]<MiB>` in PVE 9.
            let main = PropertyString.parse(value, defaultKey: "current")["current"] ?? value
            return Int(main) ?? Double(main).map { Int($0) }
        }
    }

    /// Current value, as running now.
    public func current(_ key: String) -> Int? { int(key, pending: false) }
    /// Value after the next restart.
    public func effective(_ key: String) -> Int? { int(key, pending: true) }

    public func isPending(_ key: String) -> Bool { entries[key]?.hasPendingChange ?? false }

    // Defaults when a key is absent (the schema defaults).
    public var cores: Int { effective("cores") ?? 1 }
    public var sockets: Int { effective("sockets") ?? 1 }
    /// MiB.
    public var memory: Int { effective("memory") ?? 512 }
    /// MiB; nil when not set (VM: defaults to memory), 0 = ballooning disabled.
    public var balloon: Int? { effective("balloon") }
    /// MiB (CT).
    public var swap: Int { effective("swap") ?? 512 }

    public var disks: [GuestDisk] {
        entries.values
            .compactMap { entry -> GuestDisk? in
                guard let value = entry.value ?? entry.pending, GuestDisk.isDisk(key: entry.key, value: value, type: type) else { return nil }
                return GuestDisk(key: entry.key, config: value, pendingConfig: entry.pending)
            }
            .sorted { lhs, rhs in
                if lhs.key == "rootfs" { return true }
                if rhs.key == "rootfs" { return false }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
    }
}

/// Processor / memory changes (`PUT /nodes/{node}/{type}/{vmid}/config`).
public struct HardwareChange: Sendable, Hashable {
    public var cores: Int?
    public var sockets: Int?
    /// MiB.
    public var memory: Int?
    /// MiB, VM only. 0 disables ballooning.
    public var balloon: Int?
    /// MiB, CT only.
    public var swap: Int?

    public init(cores: Int? = nil, sockets: Int? = nil, memory: Int? = nil, balloon: Int? = nil, swap: Int? = nil) {
        self.cores = cores
        self.sockets = sockets
        self.memory = memory
        self.balloon = balloon
        self.swap = swap
    }

    /// The WebUI rejects a minimum memory above the memory.
    public var isValid: Bool {
        if let cores, cores < 1 { return false }
        if let sockets, !(1...4).contains(sockets) { return false }
        if let memory, memory < 16 { return false }
        if let balloon, let memory, balloon > memory { return false }
        if let swap, swap < 0 { return false }
        return true
    }

    public func qemuRequest(_ guest: GuestRef) -> PVEAPI.PutNodesQemuConfig {
        var request = PVEAPI.PutNodesQemuConfig(node: guest.node, vmid: guest.vmid)
        request.cores = cores
        request.sockets = sockets
        request.memory = memory.map(String.init)
        request.balloon = balloon
        return request
    }

    public func lxcRequest(_ guest: GuestRef) -> PVEAPI.PutNodesLxcConfig {
        var request = PVEAPI.PutNodesLxcConfig(node: guest.node, vmid: guest.vmid)
        request.cores = cores
        request.memory = memory
        request.swap = swap
        return request
    }
}
