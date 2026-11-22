import PVEKit
import SwiftUI

struct NodeDetailView: View {
    let connection: ServerConnection
    let node: String

    @Environment(\.scenePhase) private var scenePhase
    @State private var status: NodeStatus?
    @State private var error: ActionError?

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
                    LabeledContent("运行时间", value: Format.uptime(status.uptime))
                    if !status.loadavg.isEmpty {
                        LabeledContent("负载", value: status.loadavg.joined(separator: " / "))
                    }
                    if let wait = status.wait {
                        LabeledContent("IO 等待", value: Format.percent(wait))
                    }
                }
                Section("系统") {
                    if let model = status.cpuinfo?.model {
                        LabeledContent("CPU", value: model)
                    }
                    if let version = status.pveversion {
                        LabeledContent("PVE", value: version)
                    }
                    if let kernel = status.kversion {
                        LabeledContent("内核", value: kernel)
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }

            Section {
                NavigationLink(value: Route.nodeCharts(node)) {
                    Label("监控图表", systemImage: "chart.xyaxis.line")
                }
                NavigationLink(value: Route.tasks(node: node, vmid: nil)) {
                    Label("任务", systemImage: "list.bullet.rectangle")
                }
                let consoleAllowed = connection.allows(.sysConsole, on: aclPath)
                NavigationLink(value: Route.console(.nodeShell(node: node))) {
                    Label("Shell", systemImage: "terminal")
                }
                .disabled(!consoleAllowed)
                if !consoleAllowed {
                    NoPermissionLabel(text: "无权限：需要 Sys.Console")
                }
            }
        }
        .navigationTitle(node)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await connection.loadPermissions(path: aclPath)
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
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
