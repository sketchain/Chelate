import PVEKit
import SwiftUI

/// `/cluster/resources` grouped by node, with pull-to-refresh and periodic refresh while the
/// app is in the foreground.
struct OverviewView: View {
    let connection: ServerConnection
    @Environment(\.scenePhase) private var scenePhase
    @State private var showStorage = true

    static let refreshInterval: Duration = .seconds(10)

    var body: some View {
        List {
            if let error = connection.refreshError {
                Section {
                    ErrorBanner(message: error) { Task { await connection.refreshResources() } }
                }
            }
            if connection.resources.isEmpty && connection.lastRefresh == nil {
                Section {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            ForEach(connection.nodeGroups) { group in
                Section {
                    NavigationLink(value: Route.node(group.node)) {
                        NodeRow(node: group.node, resource: group.nodeResource)
                    }
                    ForEach(group.guests) { guest in
                        if let ref = guest.guestRef {
                            NavigationLink(value: Route.guest(ref)) {
                                GuestRow(resource: guest)
                            }
                        }
                    }
                    if showStorage {
                        ForEach(group.storages) { storage in
                            StorageRow(resource: storage)
                        }
                    }
                } header: {
                    Text(group.node)
                }
            }
            if let date = connection.lastRefresh {
                Section {
                    Text("更新于 \(date.formatted(date: .omitted, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(connection.config.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Toggle("显示存储", isOn: $showStorage)
                    if connection.config.authMethod == .password {
                        Button("退出登录", systemImage: "rectangle.portrait.and.arrow.right") {
                            Task { await connection.logout() }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .refreshable {
            await connection.refreshResources()
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await connection.refreshResources()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }
}

struct NodeRow: View {
    let node: String
    let resource: ClusterResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusDot(status: resource?.status)
                Image(systemName: "server.rack")
                Text(node).font(.headline)
                Spacer()
                Text(Names.status(resource?.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let resource, resource.isOnline {
                MetricsLine(cpu: resource.cpu, maxcpu: resource.maxcpu, memory: resource.memoryFraction, uptime: resource.uptime)
            }
        }
        .padding(.vertical, 2)
    }
}

struct GuestRow: View {
    let resource: ClusterResource

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(status: resource.status)
                Image(systemName: resource.kind == .lxc ? "shippingbox" : (resource.template ? "doc.on.doc" : "desktopcomputer"))
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(resource.vmid.map(String.init) ?? "") \(resource.displayName)")
                    .lineLimit(1)
                Spacer()
                if let lock = resource.lock {
                    Label(lock, systemImage: "lock")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(resource.template ? String(localized: "模板") : Names.status(resource.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if resource.isRunning {
                MetricsLine(cpu: resource.cpu, maxcpu: resource.maxcpu, memory: resource.memoryFraction, uptime: resource.uptime)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StorageRow: View {
    let resource: ClusterResource

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: resource.status)
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.displayName)
                if let type = resource.plugintype {
                    Text(resource.shared ? "\(type) · 共享" : type)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let fraction = resource.diskFraction {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Format.percent(fraction)).monospacedDigit()
                    Text(Format.usage(resource.disk, resource.maxdisk))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

/// Compact CPU / memory / uptime line.
struct MetricsLine: View {
    let cpu: Double?
    let maxcpu: Double?
    let memory: Double?
    let uptime: Int?

    var body: some View {
        HStack(spacing: 14) {
            Label(Format.percent(cpu), systemImage: "cpu")
            Label(Format.percent(memory), systemImage: "memorychip")
            Label(Format.uptime(uptime), systemImage: "clock")
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .labelStyle(.titleAndIcon)
    }
}
