import PVEKit
import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var editing: ServerConfig?
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// iPhone always starts on the home screen (server list).
    @State private var compactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            SidebarView(editing: $editing)
        } detail: {
            detail
        }
        .sheet(item: $editing) { config in
            ServerEditView(original: config, isNew: model.server(config.id) == nil)
        }
        .onAppear(perform: selectFirstServerIfRegular)
        .onChange(of: sizeClass) { _, _ in selectFirstServerIfRegular() }
        .onChange(of: model.pendingDeepLink) { _, link in
            // A widget link opens the detail column on iPhone too.
            if link != nil { compactColumn = .detail }
        }
    }

    /// On iPad (split view) the first server's overview is shown right away; on iPhone the app
    /// stays on the home screen.
    private func selectFirstServerIfRegular() {
        guard sizeClass == .regular, model.selection == nil, let first = model.servers.first else { return }
        model.selection = .overview(first.id)
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
        case .settings?:
            SettingsStack()
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

/// Home screen: title, one card per server (总览 / 任务), then 添加服务器 and 设置.
///
/// On iPhone the navigation bar is hidden (the title keeps "Chelate" for the back button and
/// accessibility) and the list is moved up so the title's top sits about 8 pt below the top of
/// the safe area: the list ignores the top safe area and gets a top content margin of
/// `safe area + 8 − the list's own leading padding`, where that padding is measured once from
/// the title's actual position. On iPad the sidebar keeps its (empty, inline) bar.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding var editing: ServerConfig?

    /// The list's own space above the first row, measured from the title (compact only).
    @State private var listLeadingPadding: CGFloat?
    @State private var safeTop: CGFloat = 0

    static let titleOffset: CGFloat = 8

    private var compact: Bool { sizeClass == .compact }

    private var topMargin: CGFloat {
        max(0, safeTop + Self.titleOffset - (listLeadingPadding ?? 0))
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            // Scrolls with the list. As a clear row it shares the leading edge of section
            // headers and of the row icons inside the cards.
            Section {
                ChelateWordmark()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(.vertical, 0)
                    .onGeometryChange(for: TitlePosition.self) { [margin = topMargin] proxy in
                        // Carries the margin of the layout it was measured in.
                        TitlePosition(minY: proxy.frame(in: .global).minY, margin: margin)
                    } action: { position in
                        measure(position)
                    }
            }
            .listSectionSpacing(4)
            ForEach(model.servers) { server in
                Section {
                    NavigationLink(value: SidebarItem.overview(server.id)) {
                        Label("总览", systemImage: "square.grid.2x2")
                    }
                    NavigationLink(value: SidebarItem.tasks(server.id)) {
                        Label("任务", systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text(server.displayName)
                }
            }
            Section {
                Button {
                    editing = ServerConfig()
                } label: {
                    Label("添加服务器", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("home-add-server")
                NavigationLink(value: SidebarItem.settings) {
                    Label("设置", systemImage: "gearshape")
                }
                .accessibilityIdentifier("home-settings")
            }
        }
        .contentMargins(.top, compact ? topMargin : 0, for: .scrollContent)
        .ignoresSafeArea(.container, edges: compact ? .top : [])
        .navigationTitle("Chelate")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(compact ? .hidden : .automatic, for: .navigationBar)
        .toolbar {
            if !compact {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
            }
        }
    }

    struct TitlePosition: Equatable {
        var minY: CGFloat
        var margin: CGFloat
    }

    /// First layout: the title sits at `padding + margin` from the window top (the list ignores
    /// the top safe area), which gives the list's own leading padding.
    private func measure(_ position: TitlePosition) {
        guard compact else { return }
        let top = HomeLayout.windowSafeTop
        // Rotation changes the safe area; keep the margin in step.
        if top != safeTop { safeTop = top }
        guard listLeadingPadding == nil, top > 0 else { return }
        listLeadingPadding = max(0, position.minY - position.margin)
    }
}

enum HomeLayout {
    /// Top safe area inset of the key window (status bar / Dynamic Island).
    @MainActor static var windowSafeTop: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        return window?.safeAreaInsets.top ?? 0
    }
}

/// Root of a server's navigation stack with all destinations registered.
struct ServerDetailStack: View {
    enum Root { case overview, tasks }

    let connection: ServerConnection
    let root: Root
    @Environment(AppModel.self) private var model
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
        .onChange(of: model.pendingDeepLink, initial: true) { _, link in
            applyDeepLink(link)
        }
    }

    /// Opens the node or guest a widget link points to.
    private func applyDeepLink(_ link: DeepLink?) {
        guard let link, link.server == connection.config.id else { return }
        model.pendingDeepLink = nil
        var newPath = NavigationPath()
        switch link {
        case .node(_, let node):
            newPath.append(Route.node(node))
        case .guest(_, let guest):
            newPath.append(Route.guest(guest))
        }
        path = newPath
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
