import PVEKit
import SwiftUI

/// 「克隆」 (`PVE.window.Clone`): target node, VMID (next free), name, pool, mode (linked only for
/// templates), snapshot, target storage and format.
struct CloneView: View {
    let connection: ServerConnection
    let guest: GuestRef
    let guestName: String
    let isTemplate: Bool
    let onStarted: (TrackedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nodes: [String] = []
    @State private var allowedNodes: [String]?
    @State private var target = ""
    @State private var newVMID: Int?
    @State private var vmidFree: Bool?
    @State private var name = ""
    @State private var pools: [String] = []
    @State private var pool = ""
    @State private var mode: CloneRequest.Mode
    @State private var snapshots: [Snapshot] = []
    @State private var snapshot = "current"
    @State private var storages: [NodeStorage] = []
    @State private var storage = ""
    @State private var format: DiskFormat?
    @State private var starting = false
    @State private var error: String?

    init(connection: ServerConnection, guest: GuestRef, guestName: String, isTemplate: Bool, onStarted: @escaping (TrackedTask) -> Void) {
        self.connection = connection
        self.guest = guest
        self.guestName = guestName
        self.isTemplate = isTemplate
        self.onStarted = onStarted
        _mode = State(initialValue: isTemplate ? .linked : .full)
    }

    private var selectedStorage: NodeStorage? { storages.first { $0.storage == storage } }

    private var request: CloneRequest? {
        guard let newVMID, VMID.isValid(newVMID) else { return nil }
        var request = CloneRequest(source: guest, newid: newVMID, isTemplate: isTemplate)
        request.mode = mode
        request.target = target.isEmpty ? nil : target
        request.name = name
        request.pool = pool.isEmpty ? nil : pool
        request.snapshot = snapshot
        request.storage = mode == .full && !storage.isEmpty ? storage : nil
        request.format = guest.type == .qemu && selectedStorage?.offersFormatChoice == true ? format : nil
        return request
    }

    private var needs: [PermissionNeed] {
        var list = [PermissionNeed(.vmClone, on: guest.aclPath), PermissionNeed(.vmAllocate, on: newVMID.map { PermissionNeed.vm($0) } ?? "/vms")]
        if mode == .full && !storage.isEmpty { list.append(PermissionNeed(.datastoreAllocateSpace, on: PermissionNeed.storage(storage))) }
        if !pool.isEmpty { list.append(PermissionNeed(.poolAllocate, on: "/pool/\(pool)")) }
        return list
    }

    private var problem: String? {
        guard let newVMID, VMID.isValid(newVMID) else { return String(localized: "VMID 须为 100–999999999 之间的整数") }
        if vmidFree == false { return String(localized: "VMID \(String(newVMID)) 已被使用") }
        if !name.isEmpty && !WizardValidation.isDNSName(name) { return String(localized: "名称无效") }
        if let allowedNodes, !target.isEmpty, target != guest.node, !allowedNodes.contains(target) {
            return String(localized: "所选模式下，\(target) 无法访问该客户机的全部磁盘。")
        }
        return nil
    }

    var body: some View {
        let missing = connection.missing(needs)
        NavigationStack {
            Form {
                Section {
                    Picker("目标节点", selection: $target) {
                        ForEach(nodes, id: \.self) { node in
                            Text(verbatim: node).tag(node)
                        }
                    }
                    OptionalIntField(title: guest.type == .qemu ? "VM ID" : "CT ID", value: $newVMID)
                    LabeledContent(guest.type == .lxc ? "主机名" : "名称") {
                        TextField("", text: $name)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Picker("资源池", selection: $pool) {
                        Text("无").tag("")
                        ForEach(pools, id: \.self) { pool in
                            Text(verbatim: pool).tag(pool)
                        }
                    }
                }
                Section {
                    if isTemplate {
                        Picker("模式", selection: $mode) {
                            Text("完整克隆").tag(CloneRequest.Mode.full)
                            Text("链接克隆").tag(CloneRequest.Mode.linked)
                        }
                    } else {
                        LabeledContent("模式", value: String(localized: "完整克隆"))
                    }
                    if !isTemplate && !snapshots.isEmpty {
                        Picker("快照", selection: $snapshot) {
                            Text("当前状态").tag("current")
                            ForEach(snapshots) { snapshot in
                                Text(verbatim: snapshot.name).tag(snapshot.name)
                            }
                        }
                    }
                    Picker("目标存储", selection: $storage) {
                        Text("与源相同").tag("")
                        ForEach(storages) { storage in
                            Text(verbatim: storage.storage).tag(storage.storage)
                        }
                    }
                    .disabled(mode == .linked)
                    if guest.type == .qemu, mode == .full, let selected = selectedStorage, selected.offersFormatChoice {
                        Picker("格式", selection: Binding(get: { format ?? selected.preferredFormat }, set: { format = $0 })) {
                            ForEach(selected.formatChoices) { format in
                                Text(Self.formatTitle(format)).tag(format)
                            }
                        }
                    }
                } footer: {
                    if isTemplate {
                        Text("链接克隆只能用于模板，与模板共用磁盘；完整克隆会复制全部磁盘。")
                    }
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.footnote) }
                }
                if let error {
                    Section { ErrorBanner(message: error) }
                }
                if !missing.isEmpty {
                    Section { MissingPermissionLabel(action: "克隆", missing: missing) }
                }
            }
            .navigationTitle("克隆 \(guestName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("克隆") { Task { await clone() } }
                        .disabled(request == nil || problem != nil || starting || !missing.isEmpty)
                        .accessibilityIdentifier("clone-start")
                }
            }
            .task { await prepare() }
            .onChange(of: newVMID) { _, value in Task { await checkVMID(value) } }
            .onChange(of: mode) { _, _ in Task { await verifyFeature() } }
            .onChange(of: snapshot) { _, _ in Task { await verifyFeature() } }
            .onChange(of: target) { _, node in Task { await loadStorages(node: node) } }
            .onChange(of: storage) { _, _ in format = selectedStorage?.preferredFormat }
        }
    }

    static func formatTitle(_ format: DiskFormat) -> String {
        switch format {
        case .raw: return String(localized: "原始磁盘映像 (raw)")
        case .qcow2: return String(localized: "QEMU 映像格式 (qcow2)")
        case .vmdk: return String(localized: "VMware 映像格式 (vmdk)")
        }
    }

    private func prepare() async {
        let status = try? await connection.client.clusterStatus()
        nodes = status?.onlineNodes ?? []
        if nodes.isEmpty { nodes = [guest.node] }
        target = guest.node
        newVMID = try? await connection.client.nextVMID()
        pools = (try? await connection.client.pools()) ?? []
        snapshots = ((try? await connection.client.snapshots(guest)) ?? []).realSnapshots
        await loadStorages(node: guest.node)
        await verifyFeature()
        await connection.loadPermissions(paths: needs.map(\.path) + ["/vms"])
    }

    private func loadStorages(node: String) async {
        storages = (try? await connection.client.nodeStorages(node: node.isEmpty ? guest.node : node, content: guest.type == .qemu ? "images" : "rootdir")) ?? []
        if !storages.contains(where: { $0.storage == storage }) { storage = "" }
    }

    /// Nodes where all disks are available for the mode (`/feature`, VMs only).
    private func verifyFeature() async {
        allowedNodes = try? await connection.client.cloneTargets(guest, linked: mode == .linked, snapshot: snapshot)
    }

    private func checkVMID(_ value: Int?) async {
        guard let value, VMID.isValid(value) else { vmidFree = nil; return }
        vmidFree = try? await connection.client.isVMIDFree(value)
        await connection.loadPermissions(path: PermissionNeed.vm(value))
    }

    private func clone() async {
        guard let request else { return }
        starting = true
        defer { starting = false }
        let result = await connection.run(.vmClone, on: guest.aclPath) { client in
            try await client.clone(request)
        }
        switch result {
        case .success(let upid):
            onStarted(TrackedTask(upid: upid, title: String(localized: "克隆 \(guestName) → \(String(request.newid))")))
        case .failure(let failure):
            error = failure.message
        }
    }
}

/// 「迁移」 (`PVE.window.Migrate`): target node; running VMs migrate online (with a target
/// storage for local disks), running CTs in restart mode; precondition messages as in the WebUI.
struct MigrateView: View {
    let connection: ServerConnection
    let guest: GuestRef
    let guestName: String
    let isRunning: Bool
    let onStarted: (TrackedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nodes: [String] = []
    @State private var target = ""
    @State private var check: MigrationCheck?
    @State private var storages: [NodeStorage] = []
    @State private var targetStorage = ""
    @State private var force = false
    @State private var starting = false
    @State private var error: String?

    private var running: Bool { check?.running ?? isRunning }
    private var isRoot: Bool { connection.client.auth.authID == "root@pam" && !connection.usesAPIToken }

    private var modeText: String {
        guard running else { return String(localized: "离线") }
        return guest.type == .qemu ? String(localized: "在线") : String(localized: "重启模式")
    }

    private var messages: [MigrationCheck.Message] {
        check?.messages(target: target.isEmpty ? nil : target, vmid: guest.vmid, force: force) ?? []
    }

    private var request: MigrateRequest? {
        guard !target.isEmpty else { return nil }
        var request = MigrateRequest(guest: guest, target: target, running: running, withLocalDisks: check?.hasLocalDisks ?? false)
        request.targetStorage = targetStorage.isEmpty ? nil : targetStorage
        request.force = force
        return request
    }

    var body: some View {
        let missing = connection.missing([PermissionNeed(.vmMigrate, on: guest.aclPath)])
        let blocked = guest.type == .qemu && !(check?.allowsMigration(target: target, vmid: guest.vmid, force: force) ?? false)
        NavigationStack {
            Form {
                Section {
                    LabeledContent("源节点", value: guest.node)
                    LabeledContent("模式", value: modeText)
                    Picker("目标节点", selection: $target) {
                        if target.isEmpty { Text("请选择").tag("") }
                        ForEach(nodes, id: \.self) { node in
                            Text(verbatim: node).tag(node)
                        }
                    }
                    if guest.type == .qemu && running && check?.hasLocalDisks == true {
                        Picker("目标存储", selection: $targetStorage) {
                            Text("当前布局").tag("")
                            ForEach(storages) { storage in
                                Text(verbatim: storage.storage).tag(storage.storage)
                            }
                        }
                    }
                    if guest.type == .qemu && !running && !(check?.localResources.isEmpty ?? true) && isRoot {
                        Toggle("强制", isOn: $force)
                    }
                } footer: {
                    if guest.type == .lxc && running {
                        Text("运行中的容器会先关机，迁移完成后在目标节点上重新启动。")
                    }
                }
                if !messages.isEmpty {
                    Section("检查结果") {
                        ForEach(messages) { message in
                            Label(message.text, systemImage: message.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                .foregroundStyle(message.severity == .error ? .red : .orange)
                                .font(.footnote)
                        }
                    }
                }
                if let error {
                    Section { ErrorBanner(message: error) }
                }
                if !missing.isEmpty {
                    Section { MissingPermissionLabel(action: "迁移", missing: missing) }
                }
            }
            .navigationTitle("迁移 \(guestName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("迁移") { Task { await migrate() } }
                        .disabled(request == nil || blocked || starting || !missing.isEmpty)
                        .accessibilityIdentifier("migrate-start")
                }
            }
            .task { await prepare() }
            .onChange(of: target) { _, node in Task { await refresh(target: node) } }
        }
    }

    private func prepare() async {
        await connection.loadPermissions(path: guest.aclPath)
        let status = try? await connection.client.clusterStatus()
        nodes = (status?.onlineNodes ?? []).filter { $0 != guest.node }
        if nodes.count == 1 { target = nodes[0] }
        await refresh(target: target)
    }

    private func refresh(target: String) async {
        do {
            check = try await connection.client.migrationCheck(guest, target: target.isEmpty ? nil : target)
            error = nil
        } catch {
            connection.absorb(error)
            self.error = ErrorText.message(for: error)
        }
        if !target.isEmpty {
            storages = (try? await connection.client.nodeStorages(node: target, content: "images")) ?? []
        }
    }

    private func migrate() async {
        guard let request else { return }
        starting = true
        defer { starting = false }
        let result = await connection.run(.vmMigrate, on: guest.aclPath) { client in
            try await client.migrate(request)
        }
        switch result {
        case .success(let upid):
            onStarted(TrackedTask(upid: upid, title: String(localized: "迁移 \(guestName)（\(guest.node) → \(request.target)）")))
        case .failure(let failure):
            error = failure.message
        }
    }
}

/// 「删除」 (`PVE.window.SafeDestroyGuest`): stopped guests only, the VMID must be typed.
struct DestroyGuestView: View {
    let connection: ServerConnection
    let guest: GuestRef
    let guestName: String
    let onStarted: (TrackedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: DestroyGuestRequest
    @State private var confirmation = ""
    @State private var starting = false
    @State private var error: String?

    init(connection: ServerConnection, guest: GuestRef, guestName: String, onStarted: @escaping (TrackedTask) -> Void) {
        self.connection = connection
        self.guest = guest
        self.guestName = guestName
        self.onStarted = onStarted
        _draft = State(initialValue: DestroyGuestRequest(guest: guest))
    }

    var body: some View {
        let missing = connection.missing([PermissionNeed(.vmAllocate, on: guest.aclPath)])
        NavigationStack {
            Form {
                Section {
                    Label("将永久删除 \(guestName)（\(String(guest.vmid))）及其配置，无法撤销。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Toggle("从作业配置中清除", isOn: $draft.purge)
                    Toggle("删除该客户机拥有的未引用磁盘", isOn: $draft.destroyUnreferencedDisks)
                } footer: {
                    Text("“从作业配置中清除”会把它从复制、高可用和备份作业中移除；“删除未引用磁盘”会扫描所有已启用的存储。被引用的磁盘总会被删除。")
                }
                Section {
                    TextField(String(guest.vmid), text: $confirmation)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("destroy-confirmation")
                } header: {
                    Text("请输入 VMID \(String(guest.vmid)) 以确认")
                }
                if let error {
                    Section { ErrorBanner(message: error) }
                }
                if !missing.isEmpty {
                    Section { MissingPermissionLabel(action: "删除", missing: missing) }
                }
            }
            .navigationTitle("删除 \(guestName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("删除", role: .destructive) { Task { await destroy() } }
                        .tint(.red)
                        .disabled(!draft.confirms(confirmation) || starting || !missing.isEmpty)
                        .accessibilityIdentifier("destroy-start")
                }
            }
        }
    }

    private func destroy() async {
        starting = true
        defer { starting = false }
        let request = draft
        let result = await connection.run(.vmAllocate, on: guest.aclPath) { client in
            try await client.destroy(request)
        }
        switch result {
        case .success(let upid):
            onStarted(TrackedTask(upid: upid, title: String(localized: "删除 \(guestName)")))
        case .failure(let failure):
            error = failure.message
        }
    }
}
