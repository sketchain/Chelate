import AppIntents
import Foundation

/// A server from the App Group mirror.
struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "服务器"
    static let defaultQuery = ServerQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ServerQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        all()
    }

    func defaultResult() async -> ServerEntity? {
        all().first
    }

    private func all() -> [ServerEntity] {
        SharedContainer.loadServers().map { ServerEntity(id: $0.id, name: $0.displayName) }
    }
}

/// A node of a server (`<server uuid>/<node>`), known from the cached snapshots.
struct NodeEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "节点"
    static let defaultQuery = NodeQuery()

    var id: String
    var serverID: UUID
    var node: String
    var serverName: String

    init(serverID: UUID, node: String, serverName: String) {
        self.id = NodeSnapshot.cacheKey(server: serverID, node: node)
        self.serverID = serverID
        self.node = node
        self.serverName = serverName
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(node)", subtitle: "\(serverName)")
    }
}

struct NodeQuery: EntityQuery {
    @IntentParameterDependency<NodeWidgetIntent>(\.$server)
    var widgetIntent

    func entities(for identifiers: [String]) async throws -> [NodeEntity] {
        all(server: nil).filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [NodeEntity] {
        all(server: widgetIntent?.server.id)
    }

    func defaultResult() async -> NodeEntity? {
        all(server: widgetIntent?.server.id).first
    }

    /// Nodes of one server (or of all servers), from the snapshot cache.
    func all(server: UUID?) -> [NodeEntity] {
        let servers = SharedContainer.loadServers().filter { server == nil || $0.id == server }
        let cache = SharedContainer.loadCache()
        return servers.flatMap { config in
            cache.values
                .filter { $0.serverID == config.id }
                .map(\.node)
                .sorted()
                .map { NodeEntity(serverID: config.id, node: $0, serverName: config.displayName) }
        }
    }
}

/// Configuration of the node widget: which server and node to show.
struct NodeWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "节点状态"
    static let description = IntentDescription("显示一个 Proxmox VE 节点的 CPU、内存和运行中的虚拟机。")

    @Parameter(title: "服务器")
    var server: ServerEntity?

    @Parameter(title: "节点")
    var node: NodeEntity?

    init() {}

    init(server: ServerEntity?, node: NodeEntity?) {
        self.server = server
        self.node = node
    }
}
