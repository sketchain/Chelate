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
                        ResourceRow(resource: group.nodeResource, kind: .node, name: group.node)
                    }
                    .accessibilityIdentifier("node-\(group.node)")
                    ForEach(group.guests) { guest in
                        if let ref = guest.guestRef {
                            NavigationLink(value: Route.guest(ref)) {
                                ResourceRow(resource: guest, kind: guest.kind, name: guest.displayName)
                            }
                            .accessibilityIdentifier("guest-\(ref.vmid)")
                        }
                    }
                    if showStorage {
                        ForEach(group.storages) { storage in
                            NavigationLink(value: Route.storage(node: group.node, storage: storage.displayName)) {
                                ResourceRow(resource: storage, kind: .storage, name: storage.displayName)
                            }
                            .accessibilityIdentifier("storage-\(storage.displayName)")
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

/// Overview row, two lines high, four columns:
///
///     ●   [icon]   name                             ›
///         100      CPU 1.0%   内存 13%   29天6小时
///
/// Status dot and chevron are vertically centred; the separator starts at the name column.
struct ResourceRow: View {
    let resource: ClusterResource?
    let kind: ClusterResource.Kind
    let name: String

    @ScaledMetric(relativeTo: .caption) private var typeColumnWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 12) {
            OverviewStatusDot(active: isActive)
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: iconSize, height: iconSize)
                Text(verbatim: typeLabel)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: typeColumnWidth)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let lock = resource?.lock {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel(Text("已锁定：\(lock)"))
                    }
                }
                secondLine
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var isActive: Bool {
        guard let status = resource?.status else { return false }
        return status == "running" || status == "online" || status == "available"
    }

    private var icon: String {
        switch kind {
        case .node: return "server.rack"
        case .qemu: return "desktopcomputer"
        case .lxc: return "shippingbox"
        case .storage: return "externaldrive"
        default: return "questionmark.square"
        }
    }

    /// Never empty: vmid for guests, otherwise the kind.
    private var typeLabel: String {
        switch kind {
        case .node: return String(localized: "节点")
        case .storage: return String(localized: "存储")
        case .qemu, .lxc:
            if let vmid = resource?.vmid { return String(vmid) }
            return kind == .qemu ? String(localized: "虚拟机") : String(localized: "容器")
        default: return String(localized: "资源")
        }
    }

    @ViewBuilder
    private var secondLine: some View {
        if kind == .storage {
            if let resource, let fraction = resource.diskFraction {
                Text(verbatim: "\(Format.usage(resource.disk, resource.maxdisk)) · \(Format.percent(fraction))")
                    .monospacedDigit()
            } else {
                Text(Names.status(resource?.status))
            }
        } else if let resource, resource.template {
            Text("模板")
        } else if let resource, (kind == .node && resource.isOnline) || resource.isRunning {
            MetricsLine(cpu: resource.cpu, memory: resource.memoryFraction, uptime: resource.uptime)
        } else {
            Text(Names.status(resource?.status))
        }
    }
}

/// Overview status: green when running / online / available, grey otherwise.
struct OverviewStatusDot: View {
    let active: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(active ? Color.green : Color.gray)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// CPU / memory / uptime with fixed column widths so rows line up.
struct MetricsLine: View {
    let cpu: Double?
    let memory: Double?
    let uptime: Int?

    @ScaledMetric(relativeTo: .caption) private var metricWidth: CGFloat = 62

    var body: some View {
        HStack(spacing: 6) {
            metric("cpu", Format.percent(cpu), label: "CPU")
                .frame(width: metricWidth, alignment: .leading)
            metric("memorychip", Format.percent(memory), label: "内存")
                .frame(width: metricWidth, alignment: .leading)
            metric("clock", Format.uptime(uptime), label: "运行时间")
        }
        .monospacedDigit()
    }

    private func metric(_ icon: String, _ value: String, label: LocalizedStringKey) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(verbatim: value)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(verbatim: value))
    }
}
