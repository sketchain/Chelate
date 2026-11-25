import Foundation

/// Disk image formats offered by the WebUI's format selector.
public enum DiskFormat: String, Sendable, Hashable, CaseIterable, Identifiable {
    case raw, qcow2, vmdk
    public var id: String { rawValue }
}

/// One storage of `GET /nodes/{node}/storage?format=1` (the WebUI's storage selector).
public struct NodeStorage: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { storage }
    public var storage: String
    public var type: String
    public var content: Set<String>
    public var active: Bool
    public var enabled: Bool
    public var shared: Bool
    public var avail: Double?
    public var total: Double?
    public var used: Double?
    /// Formats the storage supports for new disks; empty when unknown.
    public var supportedFormats: Set<DiskFormat>
    public var defaultFormat: DiskFormat?
    /// The storage can hand out existing volumes (`select_existing`, e.g. iSCSI).
    public var selectExisting: Bool

    public init(storage: String, type: String, content: Set<String>, active: Bool = true, enabled: Bool = true, shared: Bool = false, avail: Double? = nil, total: Double? = nil, supportedFormats: Set<DiskFormat> = [.raw], defaultFormat: DiskFormat? = .raw) {
        self.storage = storage
        self.type = type
        self.content = content
        self.active = active
        self.enabled = enabled
        self.shared = shared
        self.avail = avail
        self.total = total
        self.used = nil
        self.supportedFormats = supportedFormats
        self.defaultFormat = defaultFormat
        self.selectExisting = false
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        storage = c.flexibleString(AnyCodingKey("storage")) ?? ""
        type = c.flexibleString(AnyCodingKey("type")) ?? ""
        content = Set((c.flexibleString(AnyCodingKey("content")) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        active = c.flexibleBool(AnyCodingKey("active")) ?? true
        enabled = c.flexibleBool(AnyCodingKey("enabled")) ?? true
        shared = c.flexibleBool(AnyCodingKey("shared")) ?? false
        avail = c.flexibleDouble(AnyCodingKey("avail"))
        total = c.flexibleDouble(AnyCodingKey("total"))
        used = c.flexibleDouble(AnyCodingKey("used"))
        selectExisting = c.flexibleBool(AnyCodingKey("select_existing")) ?? false
        var supported: Set<DiskFormat> = []
        var fallback: DiskFormat?
        // Newer: `formats: { supported: [...], default: "qcow2" }`.
        if let formats = try? c.decodeIfPresent(JSONValue.self, forKey: AnyCodingKey("formats")), case .object(let object) = formats {
            if case .array(let list)? = object["supported"] {
                supported = Set(list.compactMap { $0.stringValue.flatMap(DiskFormat.init(rawValue:)) })
            }
            fallback = object["default"]?.stringValue.flatMap(DiskFormat.init(rawValue:))
        } else if let format = try? c.decodeIfPresent(JSONValue.self, forKey: AnyCodingKey("format")), case .array(let pair) = format {
            // Older: `format: [{ raw: 1, qcow2: 1, ... }, "qcow2"]`.
            if let first = pair.first, case .object(let valid) = first {
                supported = Set(valid.compactMap { key, value in (value.doubleValue ?? 0) != 0 ? DiskFormat(rawValue: key) : nil })
            }
            if pair.count > 1 { fallback = pair[1].stringValue.flatMap(DiskFormat.init(rawValue:)) }
        }
        supportedFormats = supported
        defaultFormat = fallback
    }

    public func supports(_ contentType: String) -> Bool { content.contains(contentType) }

    public var isPBS: Bool { type == "pbs" }

    /// The format the WebUI preselects: qcow2 if supported, else raw, else the storage default.
    public var preferredFormat: DiskFormat {
        if supportedFormats.contains(.qcow2) { return .qcow2 }
        if supportedFormats.contains(.raw) || supportedFormats.isEmpty { return .raw }
        return defaultFormat ?? .raw
    }

    /// The format selector is enabled only with more than one choice.
    public var offersFormatChoice: Bool { supportedFormats.count > 1 }

    /// Formats in selector order.
    public var formatChoices: [DiskFormat] {
        DiskFormat.allCases.filter { supportedFormats.contains($0) }
    }
}

/// VMIDs: 100 … 999 999 999 (`pve-vmid`).
public enum VMID {
    public static let range = 100...999_999_999

    public static func isValid(_ value: Int?) -> Bool {
        guard let value else { return false }
        return range.contains(value)
    }

    /// `GET /cluster/nextid` answers with a string (or a number on some versions).
    public static func parse(_ value: JSONValue) -> Int? {
        if let number = value.doubleValue { return Int(number) }
        return nil
    }
}

/// 「Clone」 dialog (`PVE.window.Clone`): `POST /nodes/{node}/{type}/{vmid}/clone`.
public struct CloneRequest: Sendable, Hashable {
    public enum Mode: String, Sendable, Hashable, CaseIterable, Identifiable {
        /// 「Full Clone」 (`full=1`).
        case full
        /// 「Linked Clone」: templates only.
        case linked
        public var id: String { rawValue }
    }

    public var source: GuestRef
    public var newid: Int
    /// Target node; nil or the source node means local.
    public var target: String?
    public var name: String = ""
    public var pool: String?
    public var mode: Mode
    /// Snapshot to clone from (non-templates with snapshots); nil = current state.
    public var snapshot: String?
    /// Full clone only; nil = same as source.
    public var storage: String?
    /// VM full clone to a storage only.
    public var format: DiskFormat?

    public init(source: GuestRef, newid: Int, isTemplate: Bool) {
        self.source = source
        self.newid = newid
        mode = isTemplate ? .linked : .full
    }

    public func qemuRequest() -> PVEAPI.PostNodesQemuClone {
        var request = PVEAPI.PostNodesQemuClone(node: source.node, vmid: source.vmid, newid: newid)
        if let snapshot, snapshot != "current", !snapshot.isEmpty { request.snapname = snapshot }
        if let pool, !pool.isEmpty { request.pool = pool }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { request.name = trimmed }
        if let target, !target.isEmpty { request.target = target }
        if mode == .full {
            request.full = true
            if let storage, !storage.isEmpty {
                request.storage = storage
                if let format { request.format = PVEAPI.PostNodesQemuClone.Format(rawValue: format.rawValue) }
            }
        }
        return request
    }

    public func lxcRequest() -> PVEAPI.PostNodesLxcClone {
        var request = PVEAPI.PostNodesLxcClone(node: source.node, vmid: source.vmid, newid: newid)
        if let snapshot, snapshot != "current", !snapshot.isEmpty { request.snapname = snapshot }
        if let pool, !pool.isEmpty { request.pool = pool }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { request.hostname = trimmed }
        if let target, !target.isEmpty { request.target = target }
        if mode == .full {
            request.full = true
            if let storage, !storage.isEmpty { request.storage = storage }
        }
        return request
    }
}

/// Result of the migration precondition check (`GET /nodes/{node}/{type}/{vmid}/migrate`),
/// reduced to what the WebUI shows.
public struct MigrationCheck: Sendable, Hashable {
    public enum Severity: String, Sendable, Hashable { case error, warning, info }

    public struct Message: Sendable, Hashable, Identifiable {
        public var id: String { text }
        public var severity: Severity
        public var text: String
    }

    public var running: Bool
    /// Nodes the guest may move to while stopped (nil: any).
    public var allowedNodes: [String]?
    public var localDisks: [(volid: String, size: Double?, cdrom: Bool)]
    public var localResources: [String]
    public var mappedResources: [String]
    /// Per target node: storages missing there.
    public var unavailableStorages: [String: [String]]

    public init(running: Bool = false) {
        self.running = running
        allowedNodes = nil
        localDisks = []
        localResources = []
        mappedResources = []
        unavailableStorages = [:]
    }

    public init(_ output: PVEAPI.GetNodesQemuMigrate.Output) {
        running = output.running ?? false
        allowedNodes = output.allowedNodes
        localDisks = (output.localDisks ?? []).compactMap { disk in
            guard let volid = disk.volid else { return nil }
            return (volid, disk.size.map(Double.init), disk.cdrom ?? false)
        }
        localResources = output.localResources ?? []
        var mapped = output.mappedResources ?? []
        if case .object(let info)? = output.mappedResourceInfo {
            mapped = Array(Set(mapped).union(info.keys)).sorted()
        }
        mappedResources = mapped
        var unavailable: [String: [String]] = [:]
        if case .object(let nodes)? = output.notAllowedNodes {
            for (node, value) in nodes {
                if case .object(let details) = value, case .array(let storages)? = details["unavailable_storages"] {
                    unavailable[node] = storages.compactMap(\.stringValue)
                }
            }
        }
        unavailableStorages = unavailable
    }

    public init(lxc output: PVEAPI.GetNodesLxcMigrate.Output) {
        self.init(running: output.running ?? false)
    }

    /// Local disks other than cloud-init drives make the migration copy data (`with-local-disks`).
    public var hasLocalDisks: Bool { localDisks.contains { !$0.cdrom } }

    /// Messages in the WebUI's wording (translated), for a chosen target and guest.
    public func messages(target: String?, vmid: Int, force: Bool) -> [Message] {
        var result: [Message] = []
        if let target, !running, let allowedNodes, !allowedNodes.contains(target), let missing = unavailableStorages[target], !missing.isEmpty {
            result.append(Message(severity: .error, text: "目标节点上没有存储（\(missing.joined(separator: ", "))）。启动虚拟机后可在线迁移存储，或选择其他目标节点。"))
        }
        let blocking = localResources.filter { !mappedResources.contains($0) }
        if !blocking.isEmpty {
            if !force || running {
                result.append(Message(severity: .error, text: "虚拟机有本地资源，无法迁移：\(blocking.joined(separator: ", "))"))
            } else {
                result.append(Message(severity: .warning, text: "带本地资源迁移：\(blocking.joined(separator: ", "))。如果目标节点没有这些资源，迁移可能失败。"))
            }
        }
        for disk in localDisks {
            if disk.cdrom {
                if !disk.volid.contains("vm-\(vmid)-cloudinit") {
                    result.append(Message(severity: .error, text: "虚拟机挂载了本地 CD/DVD，无法迁移"))
                }
            } else {
                let size = disk.size.map { " (\(ByteFormat.string($0)))" } ?? ""
                result.append(Message(severity: .warning, text: "带本地磁盘迁移可能需要较长时间：\(disk.volid)\(size)"))
            }
        }
        return result
    }

    /// Whether the WebUI would allow starting the migration.
    public func allowsMigration(target: String?, vmid: Int, force: Bool) -> Bool {
        guard let target, !target.isEmpty else { return false }
        return !messages(target: target, vmid: vmid, force: force).contains { $0.severity == .error }
    }

    public static func == (lhs: MigrationCheck, rhs: MigrationCheck) -> Bool {
        lhs.running == rhs.running && lhs.allowedNodes == rhs.allowedNodes
            && lhs.localDisks.map(\.volid) == rhs.localDisks.map(\.volid)
            && lhs.localResources == rhs.localResources && lhs.mappedResources == rhs.mappedResources
            && lhs.unavailableStorages == rhs.unavailableStorages
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(running)
        hasher.combine(allowedNodes)
        hasher.combine(localDisks.map(\.volid))
        hasher.combine(localResources)
    }
}

/// 「Migrate」 dialog (`PVE.window.Migrate`): `POST /nodes/{node}/{type}/{vmid}/migrate`.
public struct MigrateRequest: Sendable, Hashable {
    public var guest: GuestRef
    public var target: String
    /// Guest running: VMs migrate online, CTs in restart mode.
    public var running: Bool
    public var withLocalDisks: Bool
    /// Running VM with local disks: target storage (nil = current layout).
    public var targetStorage: String?
    /// 「Force」: ignore the local resources check (stopped VM, root@pam).
    public var force = false
    /// Restart mode timeout for CTs (seconds); nil = server default (180).
    public var restartTimeout: Int?

    public init(guest: GuestRef, target: String, running: Bool, withLocalDisks: Bool = false) {
        self.guest = guest
        self.target = target
        self.running = running
        self.withLocalDisks = withLocalDisks
    }

    public func qemuRequest() -> PVEAPI.PostNodesQemuMigrate {
        var request = PVEAPI.PostNodesQemuMigrate(node: guest.node, vmid: guest.vmid, target: target)
        if running { request.online = true }
        if withLocalDisks { request.withLocalDisks = true }
        if withLocalDisks && running, let targetStorage, !targetStorage.isEmpty { request.targetstorage = targetStorage }
        if force { request.force = true }
        return request
    }

    public func lxcRequest() -> PVEAPI.PostNodesLxcMigrate {
        var request = PVEAPI.PostNodesLxcMigrate(node: guest.node, vmid: guest.vmid, target: target)
        if running {
            request.restart = true
            request.timeout = restartTimeout
        }
        return request
    }
}

/// 「Remove」 (`PVE.window.SafeDestroyGuest`): `DELETE /nodes/{node}/{type}/{vmid}`.
public struct DestroyGuestRequest: Sendable, Hashable {
    public var guest: GuestRef
    /// 「Purge from job configurations」: replication, HA and backup jobs.
    public var purge = false
    /// 「Destroy unreferenced disks owned by guest」.
    public var destroyUnreferencedDisks = false

    public init(guest: GuestRef) {
        self.guest = guest
    }

    /// The confirmation text must equal the VMID.
    public func confirms(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces) == String(guest.vmid)
    }

    public func qemuRequest() -> PVEAPI.DeleteNodesQemuByVmid {
        var request = PVEAPI.DeleteNodesQemuByVmid(node: guest.node, vmid: guest.vmid)
        request.purge = purge
        request.destroyUnreferencedDisks = destroyUnreferencedDisks
        return request
    }

    public func lxcRequest() -> PVEAPI.DeleteNodesLxcByVmid {
        var request = PVEAPI.DeleteNodesLxcByVmid(node: guest.node, vmid: guest.vmid)
        request.purge = purge
        request.destroyUnreferencedDisks = destroyUnreferencedDisks
        return request
    }
}
