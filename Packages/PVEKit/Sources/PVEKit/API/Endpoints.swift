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

extension PVEClient {
    // MARK: Cluster / nodes

    public func version() async throws -> VersionInfo {
        try await request(.get, "/version")
    }

    public func clusterResources() async throws -> [ClusterResource] {
        try await request(.get, "/cluster/resources")
    }

    public func nodeStatus(node: String) async throws -> NodeStatus {
        try await request(.get, PathBuilder.path("nodes", node, "status"))
    }

    public func permissions(path: String? = nil) async throws -> PermissionMap {
        try await request(.get, "/access/permissions", query: path.map { [URLQueryItem(name: "path", value: $0)] } ?? [])
    }

    // MARK: Guests

    public func guestStatus(_ guest: GuestRef) async throws -> GuestStatus {
        try await request(.get, guest.basePath + "/status/current")
    }

    public func guestConfig(_ guest: GuestRef) async throws -> GuestConfig {
        try await request(.get, guest.basePath + "/config")
    }

    /// Returns the UPID of the started task.
    public func power(_ action: PowerAction, guest: GuestRef) async throws -> String {
        try await request(.post, guest.basePath + "/status/" + action.rawValue, form: [])
    }

    // MARK: RRD

    public func nodeRRD(node: String, timeframe: RRDTimeframe) async throws -> [RRDPoint] {
        try await request(.get, PathBuilder.path("nodes", node, "rrddata"), query: rrdQuery(timeframe))
    }

    public func guestRRD(_ guest: GuestRef, timeframe: RRDTimeframe) async throws -> [RRDPoint] {
        try await request(.get, guest.basePath + "/rrddata", query: rrdQuery(timeframe))
    }

    private func rrdQuery(_ timeframe: RRDTimeframe) -> [URLQueryItem] {
        [URLQueryItem(name: "timeframe", value: timeframe.rawValue), URLQueryItem(name: "cf", value: "AVERAGE")]
    }

    // MARK: Tasks

    public func clusterTasks() async throws -> [TaskSummary] {
        try await request(.get, "/cluster/tasks")
    }

    public func nodeTasks(node: String, limit: Int = 50, vmid: Int? = nil) async throws -> [TaskSummary] {
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let vmid { query.append(URLQueryItem(name: "vmid", value: String(vmid))) }
        return try await request(.get, PathBuilder.path("nodes", node, "tasks"), query: query)
    }

    public func taskStatus(node: String, upid: String) async throws -> TaskStatus {
        try await request(.get, PathBuilder.path("nodes", node, "tasks", upid, "status"))
    }

    public func taskLog(node: String, upid: String, start: Int = 0, limit: Int = 1000) async throws -> [TaskLogLine] {
        try await request(.get, PathBuilder.path("nodes", node, "tasks", upid, "log"), query: [
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    // MARK: Snapshots

    public func snapshots(_ guest: GuestRef) async throws -> [Snapshot] {
        try await request(.get, guest.basePath + "/snapshot")
    }

    public func createSnapshot(_ guest: GuestRef, name: String, description: String?, includeRAM: Bool) async throws -> String {
        var form: [(String, String)] = [("snapname", name)]
        if let description, !description.isEmpty { form.append(("description", description)) }
        if guest.type == .qemu, includeRAM { form.append(("vmstate", "1")) }
        return try await request(.post, guest.basePath + "/snapshot", form: form)
    }

    public func rollbackSnapshot(_ guest: GuestRef, name: String) async throws -> String {
        try await request(.post, guest.basePath + "/snapshot/" + PathBuilder.escape(name) + "/rollback", form: [])
    }

    public func deleteSnapshot(_ guest: GuestRef, name: String) async throws -> String {
        try await request(.delete, guest.basePath + "/snapshot/" + PathBuilder.escape(name))
    }

    // MARK: Consoles

    /// `POST .../termproxy`, then the caller connects `vncwebsocket` and speaks `TermProxyProtocol`.
    public func termProxy(_ target: ConsoleTarget) async throws -> ProxyTicket {
        try await request(.post, target.proxyPath, form: [])
    }

    public func termProxyWebSocketRequest(_ target: ConsoleTarget, ticket: ProxyTicket) async throws -> URLRequest {
        try await webSocketRequest(path: target.webSocketPath, port: ticket.port, vncTicket: ticket.ticket)
    }

    /// `POST /nodes/{node}/qemu/{vmid}/vncproxy` with `websocket=1`. The VNC password is the ticket.
    public func vncProxy(_ guest: GuestRef) async throws -> ProxyTicket {
        try await request(.post, guest.basePath + "/vncproxy", form: [("websocket", "1")])
    }

    public func vncWebSocketRequest(_ guest: GuestRef, ticket: ProxyTicket) async throws -> URLRequest {
        try await webSocketRequest(path: guest.basePath + "/vncwebsocket", port: ticket.port, vncTicket: ticket.ticket)
    }
}
