import PVEKit
import SwiftUI

struct NodeDetailView: View {
    let connection: ServerConnection
    let node: String

    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings
    @State private var status: NodeStatus?
    @State private var error: ActionError?
    @State private var creating: CreateGuestKind?
    @State private var tracked: TrackedTask?

    private var aclPath: String { "/nodes/\(node)" }

    var body: some View {
        List {
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看节点状态（需要 Sys.Audit）")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            if let status {
                Section("状态") {
                    UsageBar(title: "CPU", fraction: status.cpu, detail: "\(Format.percent(status.cpu)) · \(status.cpuinfo?.cpus ?? 0) 线程")
                    UsageBar(title: "内存", fraction: status.memory?.fraction, detail: Format.usage(status.memory?.used, status.memory?.total))
                    UsageBar(title: "根分区", fraction: status.rootfs?.fraction, detail: Format.usage(status.rootfs?.used, status.rootfs?.total))
                    if let swap = status.swap, (swap.total ?? 0) > 0 {
                        UsageBar(title: "Swap", fraction: swap.fraction, detail: Format.usage(swap.used, swap.total))
                    }
                    InfoRow(title: "运行时间", value: Format.uptime(status.uptime))
                    if !status.loadavg.isEmpty {
                        InfoRow(title: "负载", value: status.loadavg.joined(separator: " / "))
                    }
                    if let wait = status.wait {
                        InfoRow(title: "IO 等待", value: Format.percent(wait))
                    }
                }
                Section {
                    if let model = status.cpuinfo?.model {
                        InfoRow(title: "CPU", value: model, raw: model)
                    }
                    if let version = status.pveversion {
                        InfoRow(title: "PVE", value: status.pveVersionNumber ?? version, raw: version)
                    }
                    if let kernel = status.kernelRelease {
                        InfoRow(title: "内核", value: kernel, raw: status.kversion ?? kernel)
                    }
                } header: {
                    Text("系统")
                } footer: {
                    Text("点击查看完整信息。")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }

            Section {
                NavigationLink(value: Route.nodeCharts(node)) {
                    Label("监控图表", systemImage: "chart.xyaxis.line")
                }
                .accessibilityIdentifier("node-charts")
                NavigationLink(value: Route.tasks(node: node, vmid: nil)) {
                    Label("任务", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("node-tasks")
                let consoleAllowed = connection.allows(.sysConsole, on: aclPath)
                NavigationLink(value: Route.console(.nodeShell(node: node))) {
                    Label("Shell", systemImage: "terminal")
                }
                .disabled(!consoleAllowed)
                if !consoleAllowed {
                    NoPermissionLabel(text: "无权限：需要 Sys.Console")
                }
                NavigationLink(value: Route.syslog(node)) {
                    Label("系统日志", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("node-syslog")
                NavigationLink(value: Route.aptUpdates(node)) {
                    Label("更新", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("node-updates")
                NavigationLink(value: Route.firewall(.node(node))) {
                    Label("防火墙", systemImage: "flame")
                }
            }
            Section("新建") {
                Button { creating = .vm } label: {
                    Label("新建虚拟机", systemImage: "desktopcomputer.and.arrow.down")
                }
                .accessibilityIdentifier("node-create-vm")
                Button { creating = .ct } label: {
                    Label("新建容器", systemImage: "shippingbox")
                }
                .accessibilityIdentifier("node-create-ct")
            }
            NotesSection(
                canEdit: connection.missing([PermissionNeed(.sysModify, on: aclPath)]).isEmpty,
                missingText: {
                    let missing = connection.missing([PermissionNeed(.sysModify, on: aclPath)])
                    return missing.isEmpty ? nil : ServerConnection.describe(missing)
                }(),
                load: { try await connection.client.nodeNotes(node: node) },
                save: { text in try await connection.client.setNodeNotes(node: node, text) }
            )
        }
        .navigationTitle(node)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $creating) { kind in
            CreateGuestWizard(connection: connection, kind: kind, presetNode: node) { task in
                creating = nil
                tracked = task
            }
        }
        .sheet(item: $tracked) { task in
            TaskMonitorSheet(connection: connection, task: task) {
                Task { await connection.refreshResources() }
            }
        }
        .refreshable { await load() }
        .task(id: RefreshTrigger(phase: scenePhase, interval: settings.autoRefresh)) {
            guard scenePhase == .active else { return }
            await connection.loadPermissions(path: aclPath)
            await autoRefresh(settings.autoRefresh) { await load() }
        }
    }

    private func load() async {
        let result = await connection.run(.sysAudit, on: aclPath) { client in
            try await client.nodeStatus(node: node)
        }
        switch result {
        case .success(let value):
            status = value
            error = nil
        case .failure(let failure):
            if case .failed(let message) = failure, message == ErrorText.message(for: PVEError.cancelled) { return }
            error = failure
        }
    }
}
