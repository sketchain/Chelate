import PVEKit
import SwiftUI

struct GuestDetailView: View {
    let connection: ServerConnection
    let guest: GuestRef

    @Environment(\.scenePhase) private var scenePhase
    @State private var status: GuestStatus?
    @State private var loadError: String?
    @State private var pendingAction: PowerAction?
    @State private var actionMessage: String?
    @State private var tracked: TrackedTask?
    @State private var busy = false

    private var name: String {
        status?.name ?? connection.resource(for: guest)?.name ?? "\(guest.vmid)"
    }

    var body: some View {
        List {
            if let loadError {
                Section { ErrorBanner(message: loadError) { Task { await load() } } }
            }
            statusSection
            powerSection
            Section("更多") {
                NavigationLink(value: Route.guestCharts(guest)) {
                    Label("监控图表", systemImage: "chart.xyaxis.line")
                }
                NavigationLink(value: Route.config(guest)) {
                    Label("配置", systemImage: "slider.horizontal.3")
                }
                NavigationLink(value: Route.snapshots(guest)) {
                    Label("快照", systemImage: "camera.on.rectangle")
                }
                NavigationLink(value: Route.tasks(node: guest.node, vmid: guest.vmid)) {
                    Label("任务历史", systemImage: "list.bullet.rectangle")
                }
            }
            consoleSection
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await connection.loadPermissions(path: guest.aclPath)
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(
            pendingAction.map(Names.power) ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(Names.power(action), role: .destructive) {
                Task { await perform(action) }
            }
        } message: { action in
            Text(Names.powerConfirmation(action, name: name))
        }
        .alert("操作未完成", isPresented: Binding(get: { actionMessage != nil }, set: { if !$0 { actionMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(actionMessage ?? "")
        }
        .sheet(item: $tracked) { task in
            TaskMonitorSheet(connection: connection, task: task) {
                Task { await load() }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("状态") {
            if let status {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        StatusDot(status: status.effectiveState)
                        Text(Names.status(status.effectiveState))
                    }
                }
                LabeledContent("类型", value: "\(Names.guestType(guest.type)) · \(guest.vmid)")
                LabeledContent("节点", value: guest.node)
                if status.isRunning {
                    UsageBar(title: "CPU", fraction: status.cpu, detail: "\(Format.percent(status.cpu)) · \(Int(status.cpus ?? 0)) 核")
                    UsageBar(title: "内存", fraction: fraction(status.mem, status.maxmem), detail: Format.usage(status.mem, status.maxmem))
                    LabeledContent("运行时间", value: Format.uptime(status.uptime))
                } else {
                    LabeledContent("内存", value: Format.bytes(status.maxmem))
                }
                if guest.type == .lxc, let maxdisk = status.maxdisk, maxdisk > 0 {
                    UsageBar(title: "根磁盘", fraction: fraction(status.disk, status.maxdisk), detail: Format.usage(status.disk, status.maxdisk))
                } else if let maxdisk = status.maxdisk, maxdisk > 0 {
                    LabeledContent("磁盘", value: Format.bytes(maxdisk))
                }
                if let lock = status.lock {
                    LabeledContent("锁定", value: lock)
                }
                if let ha = status.haState {
                    LabeledContent("HA", value: ha)
                }
            } else if loadError == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
    }

    @ViewBuilder
    private var powerSection: some View {
        let allowed = connection.allows(.vmPowerMgmt, on: guest.aclPath)
        Section {
            ForEach(availableActions, id: \.self) { action in
                Button {
                    if action.isDestructive {
                        pendingAction = action
                    } else {
                        Task { await perform(action) }
                    }
                } label: {
                    Label(Names.power(action), systemImage: Names.powerIcon(action))
                        .foregroundStyle(action == .stop ? Color.red : Color.accentColor)
                }
                .disabled(!allowed || busy)
            }
        } header: {
            Text("电源")
        } footer: {
            if !allowed {
                NoPermissionLabel(text: "无权限：需要 VM.PowerMgmt")
            }
        }
    }

    private var availableActions: [PowerAction] {
        guard let status else { return [] }
        let running = status.isRunning
        let paused = status.isPaused
        return PowerAction.available(for: guest.type).filter { action in
            switch action {
            case .start: return !running
            case .shutdown, .reboot, .stop: return running
            case .suspend: return running && !paused
            case .resume: return running && paused
            }
        }
    }

    @ViewBuilder
    private var consoleSection: some View {
        if status?.isRunning == true {
            Section {
                switch guest.type {
                case .lxc:
                    let allowed = connection.allows(.vmConsole, on: guest.aclPath)
                    NavigationLink(value: Route.console(.lxc(guest))) {
                        Label("控制台", systemImage: "terminal")
                    }
                    .disabled(!allowed)
                    if !allowed { NoPermissionLabel(text: "无权限：需要 VM.Console") }
                case .qemu:
                    let allowed = connection.allows(.vmConsole, on: guest.aclPath)
                    NavigationLink(value: Route.vnc(guest)) {
                        Label("图形控制台（VNC）", systemImage: "display")
                    }
                    .disabled(!allowed)
                    if !allowed { NoPermissionLabel(text: "无权限：需要 VM.Console") }
                }
            } header: {
                Text("控制台")
            }
        }
    }

    private func fraction(_ used: Double?, _ total: Double?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return used / total
    }

    private func load() async {
        do {
            status = try await connection.client.guestStatus(guest)
            loadError = nil
        } catch PVEError.cancelled {
        } catch is CancellationError {
        } catch {
            connection.absorb(error)
            loadError = ErrorText.message(for: error)
        }
    }

    private func perform(_ action: PowerAction) async {
        busy = true
        defer { busy = false }
        let result = await connection.run(.vmPowerMgmt, on: guest.aclPath) { client in
            try await client.power(action, guest: guest)
        }
        switch result {
        case .success(let upid):
            tracked = TrackedTask(upid: upid, title: "\(Names.power(action)) \(name)")
        case .failure(let error):
            actionMessage = error.message
        }
    }
}

struct GuestConfigView: View {
    let connection: ServerConnection
    let guest: GuestRef
    @State private var config: GuestConfig?
    @State private var error: ActionError?

    var body: some View {
        List {
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看配置（需要 VM.Audit）")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            if let config {
                Section {
                    ForEach(config.entries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(entry.value)
                                .font(.system(.body, design: entry.key == "description" ? .default : .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } footer: {
                    Text("只读。修改配置请使用 PVE 网页。")
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("配置")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        let result = await connection.run(.vmAudit, on: guest.aclPath) { client in
            try await client.guestConfig(guest)
        }
        switch result {
        case .success(let value):
            config = value
            error = nil
        case .failure(let failure):
            error = failure
        }
    }
}
