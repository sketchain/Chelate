import PVEKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ServerConfig?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Demo / screenshot mode starts on the overview instead of the server list on iPhone.
    @State private var compactColumn: NavigationSplitViewColumn = DemoMode.isEnabled ? .detail : .sidebar

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            SidebarView(editing: $editing)
                .navigationTitle("Chelate")
        } detail: {
            detail
        }
        .sheet(item: $editing) { config in
            ServerEditView(original: config, isNew: model.server(config.id) == nil)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .overview(let id)?:
            if let connection = model.connection(for: id) {
                ServerDetailStack(connection: connection, root: .overview)
                    .id(id)
            } else {
                noSelection
            }
        case .tasks(let id)?:
            if let connection = model.connection(for: id) {
                ServerDetailStack(connection: connection, root: .tasks)
                    .id("tasks-\(id)")
            } else {
                noSelection
            }
        case .about?:
            NavigationStack { AboutView() }
        case nil:
            noSelection
        }
    }

    private var noSelection: some View {
        ContentUnavailableView {
            Label("未选择服务器", systemImage: "server.rack")
        } description: {
            Text(model.servers.isEmpty ? "添加一台 Proxmox VE 服务器开始使用。" : "在左侧选择一台服务器。")
        } actions: {
            if model.servers.isEmpty {
                Button("添加服务器") { editing = ServerConfig() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var editing: ServerConfig?
    @State private var deleting: ServerConfig?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.servers) { server in
                Section {
                    NavigationLink(value: SidebarItem.overview(server.id)) {
                        Label("总览", systemImage: "square.grid.2x2")
                    }
                    NavigationLink(value: SidebarItem.tasks(server.id)) {
                        Label("任务", systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    HStack {
                        Text(server.displayName)
                        Spacer()
                        Menu {
                            Button("编辑", systemImage: "pencil") { editing = server }
                            Button("删除", systemImage: "trash", role: .destructive) { deleting = server }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("服务器操作")
                    }
                }
            }
            Section {
                Button {
                    editing = ServerConfig()
                } label: {
                    Label("添加服务器", systemImage: "plus.circle")
                }
                NavigationLink(value: SidebarItem.about) {
                    Label("关于", systemImage: "info.circle")
                }
            }
        }
        .confirmationDialog(
            "删除服务器",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { server in
            Button("删除“\(server.displayName)”", role: .destructive) {
                model.delete(server.id)
            }
        } message: { _ in
            Text("将同时删除保存在钥匙串中的凭据。")
        }
    }
}

/// Root of a server's navigation stack with all destinations registered.
struct ServerDetailStack: View {
    enum Root { case overview, tasks }

    let connection: ServerConnection
    let root: Root
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ConnectionGate(connection: connection) {
                switch root {
                case .overview: OverviewView(connection: connection)
                case .tasks: TaskListView(connection: connection, node: nil, vmid: nil)
                }
            }
            .navigationDestination(for: Route.self) { route in
                destination(route)
            }
        }
        .environment(connection)
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .node(let node):
            NodeDetailView(connection: connection, node: node)
        case .guest(let guest):
            GuestDetailView(connection: connection, guest: guest)
        case .config(let guest):
            GuestConfigView(connection: connection, guest: guest)
        case .snapshots(let guest):
            SnapshotListView(connection: connection, guest: guest)
        case .nodeCharts(let node):
            RRDChartsView(connection: connection, source: .node(node))
        case .guestCharts(let guest):
            RRDChartsView(connection: connection, source: .guest(guest))
        case .taskLog(let node, let upid):
            TaskLogView(connection: connection, node: node, upid: upid)
        case .console(let target):
            TerminalScreen(connection: connection, target: target)
        case .vnc(let guest):
            VNCConsoleScreen(connection: connection, guest: guest)
        case .tasks(let node, let vmid):
            TaskListView(connection: connection, node: node, vmid: vmid)
        case .storage(let node, let storage):
            StorageDetailView(connection: connection, node: node, storage: storage)
        }
    }
}
