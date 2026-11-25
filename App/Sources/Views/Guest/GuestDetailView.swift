import PVEKit
import SwiftUI

struct GuestDetailView: View {
    let connection: ServerConnection
    let guest: GuestRef

    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings
    @State private var status: GuestStatus?
    @State private var loadError: String?
    @State private var pendingAction: PowerAction?
    @State private var actionMessage: String?
    @State private var tracked: TrackedTask?
    @State private var busy = false
    @State private var sheet: ManagementSheet?
    @State private var confirmTemplate = false

    enum ManagementSheet: String, Identifiable {
        case clone, migrate, destroy
        var id: String { rawValue }
    }

    private var isStopped: Bool { status.map { !$0.isRunning } ?? false }
    private var isTemplate: Bool { status?.template ?? connection.resource(for: guest)?.template ?? false }
    /// Migration needs another node.
    private var hasOtherNodes: Bool { connection.nodeGroups.count > 1 }

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
                .accessibilityIdentifier("guest-charts")
                NavigationLink(value: Route.hardware(guest)) {
                    Label("硬件", systemImage: "cpu")
                }
                .accessibilityIdentifier("guest-hardware")
                NavigationLink(value: Route.firewall(.guest(guest))) {
                    Label("防火墙", systemImage: "flame")
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
            GuestBackupSection(connection: connection, guest: guest, guestName: name, isStopped: isStopped) { task in
                tracked = task
            }
            NotesSection(
                canEdit: connection.missing([PermissionNeed(.vmConfigOptions, on: guest.aclPath)]).isEmpty,
                missingText: notesMissing,
                load: { try await connection.client.guestNotes(guest) },
                save: { text in try await connection.client.setGuestNotes(guest, text) }
            )
            managementSection
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: RefreshTrigger(phase: scenePhase, interval: settings.autoRefresh)) {
            guard scenePhase == .active else { return }
            await connection.loadPermissions(path: guest.aclPath)
            await autoRefresh(settings.autoRefresh) { await load() }
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
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .clone:
                CloneView(connection: connection, guest: guest, guestName: name, isTemplate: isTemplate) { task in
                    self.sheet = nil
                    tracked = task
                }
            case .migrate:
                MigrateView(connection: connection, guest: guest, guestName: name, isRunning: status?.isRunning ?? false) { task in
                    self.sheet = nil
                    tracked = task
                }
            case .destroy:
                DestroyGuestView(connection: connection, guest: guest, guestName: name) { task in
                    self.sheet = nil
                    tracked = task
                }
            }
        }
        .confirmationDialog("转换为模板", isPresented: $confirmTemplate, titleVisibility: .visible) {
            Button("转换为模板", role: .destructive) { Task { await convertToTemplate() } }
        } message: {
            Text("\(name) 将转换为模板，此操作不可逆：模板无法再启动，只能用来克隆。")
        }
    }

    private var notesMissing: String? {
        let missing = connection.missing([PermissionNeed(.vmConfigOptions, on: guest.aclPath)])
        return missing.isEmpty ? nil : ServerConnection.describe(missing)
    }

    /// Clone, migrate, convert to template and remove.
    @ViewBuilder
    private var managementSection: some View {
        let cloneMissing = connection.missing([PermissionNeed(.vmClone, on: guest.aclPath)])
        let migrateMissing = connection.missing([PermissionNeed(.vmMigrate, on: guest.aclPath)])
        let allocateMissing = connection.missing([PermissionNeed(.vmAllocate, on: guest.aclPath)])
        Section {
            Button { sheet = .clone } label: {
                Label("克隆", systemImage: "plus.square.on.square")
            }
            .disabled(!cloneMissing.isEmpty || status == nil)
            .accessibilityIdentifier("guest-clone")
            if hasOtherNodes {
                Button { sheet = .migrate } label: {
                    Label("迁移", systemImage: "arrow.right.arrow.left")
                }
                .disabled(!migrateMissing.isEmpty || status == nil)
                .accessibilityIdentifier("guest-migrate")
            }
            if !isTemplate {
                Button { confirmTemplate = true } label: {
                    Label("转换为模板", systemImage: "doc.on.doc")
                }
                .disabled(!allocateMissing.isEmpty || !isStopped)
                .accessibilityIdentifier("guest-template")
            }
            Button(role: .destructive) { sheet = .destroy } label: {
                Label("删除", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .disabled(!allocateMissing.isEmpty || !isStopped)
            .accessibilityIdentifier("guest-destroy")
        } header: {
            Text("管理")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                MissingPermissionLabel(action: "克隆", missing: cloneMissing)
                if hasOtherNodes { MissingPermissionLabel(action: "迁移", missing: migrateMissing) }
                MissingPermissionLabel(action: "转换为模板或删除", missing: allocateMissing)
                if status != nil && !isStopped {
                    Text("转换为模板和删除只能在停机状态下进行。")
                }
            }
        }
    }

    private func convertToTemplate() async {
        busy = true
        defer { busy = false }
        let result = await connection.run(.vmAllocate, on: guest.aclPath) { client in
            try await client.convertToTemplate(guest)
        }
        switch result {
        case .success(let upid):
            if let upid {
                tracked = TrackedTask(upid: upid, title: String(localized: "转换为模板 \(name)"))
            } else {
                await load()
                await connection.refreshResources()
            }
        case .failure(let error):
            actionMessage = error.message
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
                InfoRow(title: "类型", value: "\(Names.guestType(guest.type)) · \(guest.vmid)")
                InfoRow(title: "节点", value: guest.node)
                if status.isRunning {
                    UsageBar(title: "CPU", fraction: status.cpu, detail: "\(Format.percent(status.cpu)) · \(Int(status.cpus ?? 0)) 核")
                    UsageBar(title: "内存", fraction: fraction(status.mem, status.maxmem), detail: Format.usage(status.mem, status.maxmem))
                    InfoRow(title: "运行时间", value: Format.uptime(status.uptime))
                } else {
                    InfoRow(title: "内存", value: Format.bytes(status.maxmem))
                }
                if guest.type == .lxc, let maxdisk = status.maxdisk, maxdisk > 0 {
                    UsageBar(title: "根磁盘", fraction: fraction(status.disk, status.maxdisk), detail: Format.usage(status.disk, status.maxdisk))
                } else if let maxdisk = status.maxdisk, maxdisk > 0 {
                    InfoRow(title: "磁盘", value: Format.bytes(maxdisk))
                }
                if let lock = status.lock {
                    InfoRow(title: "锁定", value: lock)
                }
                if let ha = status.haState {
                    InfoRow(title: "HA", value: ha)
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
                    if settings.needsConfirmation(action) {
                        pendingAction = action
                    } else {
                        Task { await perform(action) }
                    }
                } label: {
                    Label(Names.power(action), systemImage: Names.powerIcon(action))
                        .foregroundStyle(action == .stop ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint))
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
