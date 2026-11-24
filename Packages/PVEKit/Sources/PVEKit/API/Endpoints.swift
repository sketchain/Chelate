import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PowerAction: String, Sendable, Hashable, CaseIterable, Identifiable {
    case start, shutdown, reboot, stop, suspend, resume
    public var id: String { rawValue }

    /// Actions that lose state or interrupt the guest and need confirmation.
    public var isDestructive: Bool {
        switch self {
        case .stop, .reboot, .shutdown: return true
        default: return false
        }
    }

    /// Actions offered for a guest type (suspend/resume only for qemu in this app).
    public static func available(for type: GuestType) -> [PowerAction] {
        switch type {
        case .qemu: return [.start, .shutdown, .reboot, .stop, .suspend, .resume]
        case .lxc: return [.start, .shutdown, .reboot, .stop]
        }
    }
}

/// Where a termproxy console is opened.
public enum ConsoleTarget: Sendable, Hashable {
    case nodeShell(node: String)
    case lxc(GuestRef)

    var proxyPath: String {
        switch self {
        case .nodeShell(let node): return PathBuilder.path("nodes", node, "termproxy")
        case .lxc(let guest): return guest.basePath + "/termproxy"
        }
    }

    var webSocketPath: String {
        switch self {
        case .nodeShell(let node): return PathBuilder.path("nodes", node, "vncwebsocket")
        case .lxc(let guest): return guest.basePath + "/vncwebsocket"
        }
    }

    public var aclPath: String {
        switch self {
        case .nodeShell(let node): return "/nodes/\(node)"
        case .lxc(let guest): return guest.aclPath
        }
    }

    public var requiredPrivilege: Privilege {
        switch self {
        case .nodeShell: return .sysConsole
        case .lxc: return .vmConsole
        }
    }
}

/// The hand-written API surface used by the app. Every call goes through the generated request
/// types (`PVEAPI`, built from the PVE API schema); results are decoded into the hand-written
/// models where those are more precise than the schema (flexible numbers, derived values, …).
extension PVEClient {
    // MARK: Cluster / nodes

    public func version() async throws -> VersionInfo {
        try await send(PVEAPI.GetVersion(), as: VersionInfo.self)
    }

    public func clusterResources() async throws -> [ClusterResource] {
        try await send(PVEAPI.GetClusterResources(), as: [ClusterResource].self)
    }

    public func nodeStatus(node: String) async throws -> NodeStatus {
        try await send(PVEAPI.GetNodesStatus(node: node), as: NodeStatus.self)
    }

    public func permissions(path: String? = nil) async throws -> PermissionMap {
        var request = PVEAPI.GetAccessPermissions()
        request.pathParam = path
        return try await send(request, as: PermissionMap.self)
    }

    // MARK: Guests

    public func guestStatus(_ guest: GuestRef) async throws -> GuestStatus {
        switch guest.type {
        case .qemu: return try await send(PVEAPI.GetNodesQemuStatusCurrent(node: guest.node, vmid: guest.vmid), as: GuestStatus.self)
        case .lxc: return try await send(PVEAPI.GetNodesLxcStatusCurrent(node: guest.node, vmid: guest.vmid), as: GuestStatus.self)
        }
    }

    /// Guests of one node (`/nodes/{node}/qemu` and `/nodes/{node}/lxc`), typed by the schema.
    public func nodeGuests(node: String) async throws -> (qemu: [PVEAPI.GetNodesQemu.Item], lxc: [PVEAPI.GetNodesLxc.Item]) {
        async let qemu = send(PVEAPI.GetNodesQemu(node: node))
        async let lxc = send(PVEAPI.GetNodesLxc(node: node))
        return try await (qemu, lxc)
    }

    public func guestConfig(_ guest: GuestRef) async throws -> GuestConfig {
        switch guest.type {
        case .qemu: return try await send(PVEAPI.GetNodesQemuConfig(node: guest.node, vmid: guest.vmid), as: GuestConfig.self)
        case .lxc: return try await send(PVEAPI.GetNodesLxcConfig(node: guest.node, vmid: guest.vmid), as: GuestConfig.self)
        }
    }

    /// Returns the UPID of the started task.
    public func power(_ action: PowerAction, guest: GuestRef) async throws -> String {
        let node = guest.node, vmid = guest.vmid
        switch (guest.type, action) {
        case (.qemu, .start): return try await send(PVEAPI.PostNodesQemuStatusStart(node: node, vmid: vmid))
        case (.qemu, .shutdown): return try await send(PVEAPI.PostNodesQemuStatusShutdown(node: node, vmid: vmid))
        case (.qemu, .reboot): return try await send(PVEAPI.PostNodesQemuStatusReboot(node: node, vmid: vmid))
        case (.qemu, .stop): return try await send(PVEAPI.PostNodesQemuStatusStop(node: node, vmid: vmid))
        case (.qemu, .suspend): return try await send(PVEAPI.PostNodesQemuStatusSuspend(node: node, vmid: vmid))
        case (.qemu, .resume): return try await send(PVEAPI.PostNodesQemuStatusResume(node: node, vmid: vmid))
        case (.lxc, .start): return try await send(PVEAPI.PostNodesLxcStatusStart(node: node, vmid: vmid))
        case (.lxc, .shutdown): return try await send(PVEAPI.PostNodesLxcStatusShutdown(node: node, vmid: vmid))
        case (.lxc, .reboot): return try await send(PVEAPI.PostNodesLxcStatusReboot(node: node, vmid: vmid))
        case (.lxc, .stop): return try await send(PVEAPI.PostNodesLxcStatusStop(node: node, vmid: vmid))
        case (.lxc, .suspend): return try await send(PVEAPI.PostNodesLxcStatusSuspend(node: node, vmid: vmid))
        case (.lxc, .resume): return try await send(PVEAPI.PostNodesLxcStatusResume(node: node, vmid: vmid))
        }
    }

    // MARK: RRD

    public func nodeRRD(node: String, timeframe: RRDTimeframe) async throws -> [RRDPoint] {
        var request = PVEAPI.GetNodesRrddata(node: node, timeframe: .init(timeframe))
        request.cf = .average
        return try await send(request, as: [RRDPoint].self)
    }

    public func guestRRD(_ guest: GuestRef, timeframe: RRDTimeframe) async throws -> [RRDPoint] {
        switch guest.type {
        case .qemu:
            var request = PVEAPI.GetNodesQemuRrddata(node: guest.node, vmid: guest.vmid, timeframe: .init(timeframe))
            request.cf = .average
            return try await send(request, as: [RRDPoint].self)
        case .lxc:
            var request = PVEAPI.GetNodesLxcRrddata(node: guest.node, vmid: guest.vmid, timeframe: .init(timeframe))
            request.cf = .average
            return try await send(request, as: [RRDPoint].self)
        }
    }

    // MARK: Tasks

    public func clusterTasks() async throws -> [TaskSummary] {
        try await send(PVEAPI.GetClusterTasks(), as: [TaskSummary].self)
    }

    public func nodeTasks(node: String, limit: Int = 50, vmid: Int? = nil) async throws -> [TaskSummary] {
        var request = PVEAPI.GetNodesTasks(node: node)
        request.limit = limit
        request.vmid = vmid
        return try await send(request, as: [TaskSummary].self)
    }

    public func taskStatus(node: String, upid: String) async throws -> TaskStatus {
        try await send(PVEAPI.GetNodesTasksStatus(node: node, upid: upid), as: TaskStatus.self)
    }

    public func taskLog(node: String, upid: String, start: Int = 0, limit: Int = 1000) async throws -> [TaskLogLine] {
        var request = PVEAPI.GetNodesTasksLog(node: node, upid: upid)
        request.start = start
        request.limit = limit
        return try await send(request, as: [TaskLogLine].self)
    }

    // MARK: Snapshots

    public func snapshots(_ guest: GuestRef) async throws -> [Snapshot] {
        switch guest.type {
        case .qemu: return try await send(PVEAPI.GetNodesQemuSnapshot(node: guest.node, vmid: guest.vmid), as: [Snapshot].self)
        case .lxc: return try await send(PVEAPI.GetNodesLxcSnapshot(node: guest.node, vmid: guest.vmid), as: [Snapshot].self)
        }
    }

    public func createSnapshot(_ guest: GuestRef, name: String, description: String?, includeRAM: Bool) async throws -> String {
        let note = description.flatMap { $0.isEmpty ? nil : $0 }
        switch guest.type {
        case .qemu:
            var request = PVEAPI.PostNodesQemuSnapshot(node: guest.node, vmid: guest.vmid, snapname: name)
            request.description = note
            request.vmstate = includeRAM ? true : nil
            return try await send(request)
        case .lxc:
            var request = PVEAPI.PostNodesLxcSnapshot(node: guest.node, vmid: guest.vmid, snapname: name)
            request.description = note
            return try await send(request)
        }
    }

    public func rollbackSnapshot(_ guest: GuestRef, name: String) async throws -> String {
        switch guest.type {
        case .qemu: return try await send(PVEAPI.PostNodesQemuSnapshotRollback(node: guest.node, vmid: guest.vmid, snapname: name))
        case .lxc: return try await send(PVEAPI.PostNodesLxcSnapshotRollback(node: guest.node, vmid: guest.vmid, snapname: name))
        }
    }

    public func deleteSnapshot(_ guest: GuestRef, name: String) async throws -> String {
        switch guest.type {
        case .qemu: return try await send(PVEAPI.DeleteNodesQemuSnapshotBySnapname(node: guest.node, vmid: guest.vmid, snapname: name))
        case .lxc: return try await send(PVEAPI.DeleteNodesLxcSnapshotBySnapname(node: guest.node, vmid: guest.vmid, snapname: name))
        }
    }

    // MARK: Storage

    public func storageStatus(node: String, storage: String) async throws -> StorageStatus {
        try await send(PVEAPI.GetNodesStorageStatus(node: node, storage: storage), as: StorageStatus.self)
    }

    public func storageContent(node: String, storage: String, content: StorageContentType? = nil) async throws -> [StorageContentItem] {
        var request = PVEAPI.GetNodesStorageContent(node: node, storage: storage)
        request.content = content?.rawValue
        return try await send(request, as: [StorageContentItem].self)
    }

    /// `GET /nodes/{node}/query-url-metadata`: file name, size and MIME type of a URL.
    public func queryURLMetadata(node: String, url: String, verifyCertificates: Bool = true) async throws -> URLMetadata {
        var request = PVEAPI.GetNodesQueryUrlMetadata(node: node, url: url.trimmingCharacters(in: .whitespacesAndNewlines))
        request.verifyCertificates = verifyCertificates
        return try await send(request, as: URLMetadata.self)
    }

    /// `POST /nodes/{node}/storage/{storage}/download-url`. Returns the UPID.
    public func downloadURL(node: String, storage: String, _ download: DownloadURLRequest) async throws -> String {
        try await send(download.request(node: node, storage: storage))
    }

    /// `GET /nodes/{node}/aplinfo`: official appliance / CT templates.
    public func applianceTemplates(node: String) async throws -> [ApplianceTemplate] {
        try await send(PVEAPI.GetNodesAplinfo(node: node), as: [ApplianceTemplate].self)
    }

    /// `POST /nodes/{node}/aplinfo`: downloads a template to `storage`. Returns the UPID.
    public func downloadApplianceTemplate(node: String, storage: String, template: String) async throws -> String {
        try await send(PVEAPI.PostNodesAplinfo(node: node, storage: storage, template: template))
    }

    // MARK: Consoles

    /// `POST .../termproxy`, then the caller connects `vncwebsocket` and speaks `TermProxyProtocol`.
    public func termProxy(_ target: ConsoleTarget) async throws -> ProxyTicket {
        switch target {
        case .nodeShell(let node):
            return try await send(PVEAPI.PostNodesTermproxy(node: node), as: ProxyTicket.self)
        case .lxc(let guest):
            return try await send(PVEAPI.PostNodesLxcTermproxy(node: guest.node, vmid: guest.vmid), as: ProxyTicket.self)
        }
    }

    public func termProxyWebSocketRequest(_ target: ConsoleTarget, ticket: ProxyTicket) async throws -> URLRequest {
        try await webSocketRequest(path: target.webSocketPath, port: ticket.port, vncTicket: ticket.ticket)
    }

    /// `POST /nodes/{node}/qemu/{vmid}/vncproxy` with `websocket=1`. The VNC password is the ticket.
    public func vncProxy(_ guest: GuestRef) async throws -> ProxyTicket {
        var request = PVEAPI.PostNodesQemuVncproxy(node: guest.node, vmid: guest.vmid)
        request.websocket = true
        return try await send(request, as: ProxyTicket.self)
    }

    public func vncWebSocketRequest(_ guest: GuestRef, ticket: ProxyTicket) async throws -> URLRequest {
        try await webSocketRequest(path: guest.basePath + "/vncwebsocket", port: ticket.port, vncTicket: ticket.ticket)
    }
}

extension PVEAPI.GetNodesRrddata.Timeframe {
    init(_ timeframe: RRDTimeframe) { self = Self(rawValue: timeframe.rawValue) ?? .hour }
}

extension PVEAPI.GetNodesQemuRrddata.Timeframe {
    init(_ timeframe: RRDTimeframe) { self = Self(rawValue: timeframe.rawValue) ?? .hour }
}

extension PVEAPI.GetNodesLxcRrddata.Timeframe {
    init(_ timeframe: RRDTimeframe) { self = Self(rawValue: timeframe.rawValue) ?? .hour }
}
