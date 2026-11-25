import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Backups, restore, clone, migration, removal, hardware, notes, system log, updates, HA,
/// replication and firewall. All calls go through the generated request types.
extension PVEClient {
    // MARK: VMIDs, nodes, storages, pools

    /// `GET /cluster/nextid`: the next free VMID.
    public func nextVMID() async throws -> Int {
        let value = try await send(PVEAPI.GetClusterNextid())
        guard let vmid = VMID.parse(value) else { throw PVEError.decoding("nextid") }
        return vmid
    }

    /// `GET /cluster/nextid?vmid=…` answers 400 when the VMID is taken.
    public func isVMIDFree(_ vmid: Int) async throws -> Bool {
        var request = PVEAPI.GetClusterNextid()
        request.vmid = vmid
        do {
            _ = try await send(request)
            return true
        } catch PVEError.http(let status, _) where status == 400 {
            return false
        }
    }

    public func clusterStatus() async throws -> ClusterStatus {
        ClusterStatus(try await send(PVEAPI.GetClusterStatus(), as: JSONValue.self))
    }

    /// Storages of a node usable for `content` (enabled ones, with format information).
    public func nodeStorages(node: String, content: String? = nil) async throws -> [NodeStorage] {
        var request = PVEAPI.GetNodesStorage(node: node)
        request.content = content
        request.enabled = true
        request.format = true
        return try await send(request, as: [NodeStorage].self)
            .sorted { $0.storage.localizedStandardCompare($1.storage) == .orderedAscending }
    }

    public func pools() async throws -> [String] {
        try await send(PVEAPI.GetPools()).compactMap(\.poolid).sorted()
    }

    /// Bridges of a node (`type=any_bridge`), for network devices.
    public func bridges(node: String) async throws -> [String] {
        var request = PVEAPI.GetNodesNetwork(node: node)
        request.type = .anyBridge
        return try await send(request).compactMap(\.iface).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Backups

    /// Backups of `vmid` on every storage of `node` that holds backups. Storages that fail
    /// (offline, no permission) are skipped.
    public func backups(node: String, vmid: Int) async throws -> [BackupVolume] {
        let storages = try await nodeStorages(node: node, content: "backup").filter(\.active)
        return await withTaskGroup(of: [BackupVolume].self) { group in
            for storage in storages {
                group.addTask {
                    var request = PVEAPI.GetNodesStorageContent(node: node, storage: storage.storage)
                    request.content = "backup"
                    request.vmid = vmid
                    let items = (try? await self.send(request, as: [StorageContentItem].self)) ?? []
                    return items.map { BackupVolume(storage: storage.storage, item: $0) }
                }
            }
            var all: [BackupVolume] = []
            for await part in group { all += part }
            return all.newestFirst
        }
    }

    public func vzdumpDefaults(node: String, storage: String) async throws -> PVEAPI.GetNodesVzdumpDefaults.Output {
        var request = PVEAPI.GetNodesVzdumpDefaults(node: node)
        request.storage = storage
        return try await send(request)
    }

    /// `POST /nodes/{node}/vzdump`. Returns the UPID.
    public func backup(node: String, _ backup: BackupRequest) async throws -> String {
        try await send(backup.request(node: node), as: String.self)
    }

    /// The vzdump task that wrote a backup, and the mode from its log (nil when not found).
    public func backupMode(node: String, vmid: Int, createdAt: Date) async throws -> BackupMode? {
        var request = PVEAPI.GetNodesTasks(node: node)
        request.vmid = vmid
        request.typefilter = "vzdump"
        request.since = Int(createdAt.timeIntervalSince1970) - 86_400
        request.until = Int(createdAt.timeIntervalSince1970) + 60
        request.limit = 20
        let tasks = try await send(request, as: [TaskSummary].self)
        // The archive is named after the time the guest's backup started; the task started at or
        // before that.
        guard let task = tasks
            .filter({ $0.startTime <= createdAt.addingTimeInterval(60) })
            .max(by: { $0.startTime < $1.startTime }) else { return nil }
        let log = try await taskLog(node: node, upid: task.upid, start: 0, limit: 500)
        return BackupMode.fromTaskLog(log.map(\.t), vmid: vmid)
    }

    /// `DELETE /nodes/{node}/storage/{storage}/content/{volume}`. Returns the UPID when the
    /// storage runs the removal as a task.
    public func deleteVolume(node: String, storage: String, volid: String) async throws -> String? {
        try await send(PVEAPI.DeleteNodesStorageContentByVolume(node: node, storage: storage, volume: volid), as: String?.self)
    }

    /// `GET /nodes/{node}/vzdump/extractconfig`: the guest config stored in a backup.
    public func backupConfig(node: String, volid: String) async throws -> BackupConfigSummary {
        BackupConfigSummary(config: try await send(PVEAPI.GetNodesVzdumpExtractconfig(node: node, volume: volid)))
    }

    /// Restores a backup (`POST /nodes/{node}/qemu|lxc`). Returns the UPID.
    public func restore(node: String, _ restore: RestoreRequest) async throws -> String {
        switch restore.type {
        case .qemu: return try await send(restore.qemuRequest(node: node), as: String.self)
        case .lxc: return try await send(restore.lxcRequest(node: node), as: String.self)
        }
    }

    // MARK: Clone, migrate, remove, template

    public func clone(_ clone: CloneRequest) async throws -> String {
        switch clone.source.type {
        case .qemu: return try await send(clone.qemuRequest(), as: String.self)
        case .lxc: return try await send(clone.lxcRequest(), as: String.self)
        }
    }

    /// Nodes where a (linked) clone is possible: `GET /nodes/{node}/qemu/{vmid}/feature`.
    public func cloneTargets(_ guest: GuestRef, linked: Bool, snapshot: String?) async throws -> [String]? {
        guard guest.type == .qemu else { return nil }
        var request = PVEAPI.GetNodesQemuFeature(node: guest.node, vmid: guest.vmid, feature: linked ? .clone : .copy)
        if let snapshot, snapshot != "current" { request.snapname = snapshot }
        return try await send(request).nodes
    }

    public func migrationCheck(_ guest: GuestRef, target: String?) async throws -> MigrationCheck {
        switch guest.type {
        case .qemu:
            var request = PVEAPI.GetNodesQemuMigrate(node: guest.node, vmid: guest.vmid)
            request.target = target
            return MigrationCheck(try await send(request))
        case .lxc:
            var request = PVEAPI.GetNodesLxcMigrate(node: guest.node, vmid: guest.vmid)
            request.target = target
            return MigrationCheck(lxc: try await send(request))
        }
    }

    public func migrate(_ migration: MigrateRequest) async throws -> String {
        switch migration.guest.type {
        case .qemu: return try await send(migration.qemuRequest(), as: String.self)
        case .lxc: return try await send(migration.lxcRequest(), as: String.self)
        }
    }

    public func destroy(_ destroy: DestroyGuestRequest) async throws -> String {
        switch destroy.guest.type {
        case .qemu: return try await send(destroy.qemuRequest(), as: String.self)
        case .lxc: return try await send(destroy.lxcRequest(), as: String.self)
        }
    }

    /// Converts a stopped guest into a template. VMs answer with a task, CTs without.
    public func convertToTemplate(_ guest: GuestRef) async throws -> String? {
        switch guest.type {
        case .qemu:
            return try await send(PVEAPI.PostNodesQemuTemplate(node: guest.node, vmid: guest.vmid), as: String?.self)
        case .lxc:
            _ = try await send(PVEAPI.PostNodesLxcTemplate(node: guest.node, vmid: guest.vmid), as: JSONValue?.self)
            return nil
        }
    }

    // MARK: Hardware

    public func pendingConfig(_ guest: GuestRef) async throws -> [PendingEntry] {
        switch guest.type {
        case .qemu: return try await send(PVEAPI.GetNodesQemuPending(node: guest.node, vmid: guest.vmid), as: [PendingEntry].self)
        case .lxc: return try await send(PVEAPI.GetNodesLxcPending(node: guest.node, vmid: guest.vmid), as: [PendingEntry].self)
        }
    }

    public func updateHardware(_ guest: GuestRef, _ change: HardwareChange) async throws {
        switch guest.type {
        case .qemu: _ = try await send(change.qemuRequest(guest), as: JSONValue?.self)
        case .lxc: _ = try await send(change.lxcRequest(guest), as: JSONValue?.self)
        }
    }

    /// Grows a disk. Returns the UPID when the server runs it as a task.
    public func resizeDisk(_ guest: GuestRef, _ resize: DiskResize) async throws -> String? {
        switch guest.type {
        case .qemu:
            guard let request = resize.qemuRequest(guest) else { throw PVEError.decoding("disk") }
            return try await send(request, as: String?.self)
        case .lxc:
            guard let request = resize.lxcRequest(guest) else { throw PVEError.decoding("disk") }
            return try await send(request, as: String?.self)
        }
    }

    // MARK: Notes

    public func nodeNotes(node: String) async throws -> String {
        Notes.normalized(try await send(PVEAPI.GetNodesConfig(node: node)).description)
    }

    public func setNodeNotes(node: String, _ text: String) async throws {
        var request = PVEAPI.PutNodesConfig(node: node)
        let value = Notes.normalized(text)
        if value.isEmpty { request.delete = "description" } else { request.description = value }
        _ = try await send(request, as: JSONValue?.self)
    }

    public func guestNotes(_ guest: GuestRef) async throws -> String {
        Notes.normalized(try await guestConfig(guest)["description"])
    }

    public func setGuestNotes(_ guest: GuestRef, _ text: String) async throws {
        let value = Notes.normalized(text)
        switch guest.type {
        case .qemu:
            var request = PVEAPI.PutNodesQemuConfig(node: guest.node, vmid: guest.vmid)
            if value.isEmpty { request.delete = "description" } else { request.description = value }
            _ = try await send(request, as: JSONValue?.self)
        case .lxc:
            var request = PVEAPI.PutNodesLxcConfig(node: guest.node, vmid: guest.vmid)
            if value.isEmpty { request.delete = "description" } else { request.description = value }
            _ = try await send(request, as: JSONValue?.self)
        }
    }

    // MARK: System log, updates

    public func journal(node: String, _ query: JournalQuery, idOffset: Int = 0) async throws -> JournalPage {
        JournalPage(try await send(query.request(node: node), as: JSONValue.self), idOffset: idOffset)
    }

    public func aptUpdates(node: String) async throws -> [AptPackage] {
        try await send(PVEAPI.GetNodesAptUpdate(node: node), as: [AptPackage].self).sortedForDisplay
    }

    /// `POST /nodes/{node}/apt/update` (apt update). Returns the UPID.
    public func aptRefresh(node: String) async throws -> String {
        try await send(PVEAPI.PostNodesAptUpdate(node: node), as: String.self)
    }

    public func aptChangelog(node: String, package: AptPackage) async throws -> String {
        var request = PVEAPI.GetNodesAptChangelog(node: node, name: package.name)
        request.version = package.version
        return try await send(request, as: String.self)
    }

    // MARK: HA, replication

    public func haStatus() async throws -> [HAStatusEntry] {
        try await send(PVEAPI.GetClusterHaStatusCurrent(), as: [HAStatusEntry].self)
    }

    public func haResources(status: [HAStatusEntry]) async throws -> [HAResource] {
        HAResource.merge(try await send(PVEAPI.GetClusterHaResources(), as: [HAResource].self), status: status)
    }

    /// Replication jobs with the state reported by each source node. `sourceNode` maps a guest
    /// to the node it runs on (jobs replicate from there).
    public func replicationJobs(sourceNode: @Sendable (Int) -> String?) async throws -> [ReplicationJob] {
        let jobs = try await send(PVEAPI.GetClusterReplication(), as: [ReplicationJob].self)
        let nodes = Set(jobs.compactMap { job in job.source ?? job.guest.flatMap(sourceNode) })
        var statuses: [String: ReplicationJob] = [:]
        for node in nodes {
            let list = (try? await send(PVEAPI.GetNodesReplication(node: node), as: [ReplicationJob].self)) ?? []
            for status in list { statuses[status.id] = status }
        }
        return jobs.map { $0.merging(status: statuses[$0.id]) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    // MARK: Firewall

    public func firewallOptions(_ scope: FirewallScope) async throws -> FirewallOptions {
        switch scope {
        case .datacenter:
            return try await send(PVEAPI.GetClusterFirewallOptions(), as: FirewallOptions.self)
        case .node(let node):
            return try await send(PVEAPI.GetNodesFirewallOptions(node: node), as: FirewallOptions.self)
        case .guest(let guest):
            switch guest.type {
            case .qemu: return try await send(PVEAPI.GetNodesQemuFirewallOptions(node: guest.node, vmid: guest.vmid), as: FirewallOptions.self)
            case .lxc: return try await send(PVEAPI.GetNodesLxcFirewallOptions(node: guest.node, vmid: guest.vmid), as: FirewallOptions.self)
            }
        }
    }

    public func firewallRules(_ scope: FirewallScope) async throws -> [FirewallRule] {
        let rules: [FirewallRule]
        switch scope {
        case .datacenter:
            rules = try await send(PVEAPI.GetClusterFirewallRules(), as: [FirewallRule].self)
        case .node(let node):
            rules = try await send(PVEAPI.GetNodesFirewallRules(node: node), as: [FirewallRule].self)
        case .guest(let guest):
            switch guest.type {
            case .qemu: rules = try await send(PVEAPI.GetNodesQemuFirewallRules(node: guest.node, vmid: guest.vmid), as: [FirewallRule].self)
            case .lxc: rules = try await send(PVEAPI.GetNodesLxcFirewallRules(node: guest.node, vmid: guest.vmid), as: [FirewallRule].self)
            }
        }
        return rules.sorted { $0.pos < $1.pos }
    }

    public func setFirewall(_ scope: FirewallScope, enabled: Bool) async throws {
        switch scope {
        case .datacenter:
            var request = PVEAPI.PutClusterFirewallOptions()
            request.enable = enabled ? 1 : 0
            _ = try await send(request, as: JSONValue?.self)
        case .node(let node):
            var request = PVEAPI.PutNodesFirewallOptions(node: node)
            request.enable = enabled
            _ = try await send(request, as: JSONValue?.self)
        case .guest(let guest):
            switch guest.type {
            case .qemu:
                var request = PVEAPI.PutNodesQemuFirewallOptions(node: guest.node, vmid: guest.vmid)
                request.enable = enabled
                _ = try await send(request, as: JSONValue?.self)
            case .lxc:
                var request = PVEAPI.PutNodesLxcFirewallOptions(node: guest.node, vmid: guest.vmid)
                request.enable = enabled
                _ = try await send(request, as: JSONValue?.self)
            }
        }
    }
}

extension FirewallScope {
    /// ACL path and privileges: reading needs `Sys.Audit` (`VM.Audit` for guests), changing
    /// `Sys.Modify` (`VM.Config.Network` for guests).
    public var aclPath: String {
        switch self {
        case .datacenter: return "/"
        case .node(let node): return "/nodes/\(node)"
        case .guest(let guest): return guest.aclPath
        }
    }

    public var readPrivilege: Privilege {
        if case .guest = self { return .vmAudit }
        return .sysAudit
    }

    public var modifyPrivilege: Privilege {
        if case .guest = self { return .vmConfigNetwork }
        return .sysModify
    }
}
