import PVEKit
import SwiftUI

extension BackupMode {
    var title: String {
        switch self {
        case .snapshot: return String(localized: "快照")
        case .suspend: return String(localized: "挂起")
        case .stop: return String(localized: "停机")
        }
    }
}

/// 「备份」 section of the guest detail: the guest's backups on every backup storage of its node,
/// 「立即备份」 in the header, restore on tap, delete (always confirmed) on swipe.
struct GuestBackupSection: View {
    let connection: ServerConnection
    let guest: GuestRef
    let guestName: String
    let isStopped: Bool
    var onTask: (TrackedTask) -> Void

    @State private var backups: [BackupVolume] = []
    @State private var modes: [String: BackupMode] = [:]
    @State private var loaded = false
    @State private var error: ActionError?
    @State private var showBackupNow = false
    @State private var restoreTarget: BackupVolume?
    @State private var deleteTarget: BackupVolume?
    @State private var message: String?

    private var backupNeeds: [PermissionNeed] { [PermissionNeed(.vmBackup, on: guest.aclPath)] }

    var body: some View {
        let backupMissing = connection.missing(backupNeeds)
        Section {
            if let error {
                if error.isForbidden {
                    NoPermissionLabel(text: "无权限查看备份（需要存储上的 Datastore.Audit）")
                } else {
                    ErrorBanner(message: error.message) { Task { await load() } }
                }
            } else if !loaded {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if backups.isEmpty {
                Text("没有备份").foregroundStyle(.secondary)
            }
            ForEach(backups) { backup in
                Button { restoreTarget = backup } label: {
                    BackupRow(backup: backup, mode: modes[backup.volid])
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("backup-row")
                .task { await resolveMode(backup) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除", systemImage: "trash", role: .destructive) { deleteTarget = backup }
                }
                .contextMenu {
                    Button("恢复…", systemImage: "arrow.counterclockwise") { restoreTarget = backup }
                    Button("删除备份", systemImage: "trash", role: .destructive) { deleteTarget = backup }
                }
            }
        } header: {
            HStack {
                Text("备份")
                Spacer()
                Button("立即备份") { showBackupNow = true }
                    .font(.subheadline)
                    .textCase(nil)
                    .disabled(!backupMissing.isEmpty)
                    .accessibilityIdentifier("backup-now")
            }
        } footer: {
            if !backupMissing.isEmpty {
                MissingPermissionLabel(action: "备份", missing: backupMissing)
            } else if !backups.isEmpty {
                Text("点按备份可恢复；左滑或长按可删除。")
            }
        }
        .task(id: guest) {
            await connection.loadPermissions(path: guest.aclPath)
            await load()
        }
        .sheet(isPresented: $showBackupNow) {
            BackupNowView(connection: connection, guest: guest) { task in
                showBackupNow = false
                onTask(task)
            }
        }
        .sheet(item: $restoreTarget) { backup in
            RestoreView(connection: connection, node: guest.node, backup: backup, sourceGuest: guest, sourceName: guestName, sourceIsStopped: isStopped) { task in
                restoreTarget = nil
                onTask(task)
            }
        }
        .confirmationDialog(
            "删除备份",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { backup in
            if backup.isProtected {
                Button("好") {}
            } else {
                Button("删除", role: .destructive) { Task { await delete(backup) } }
            }
        } message: { backup in
            if backup.isProtected {
                Text("该备份受保护，不能删除。请先在 PVE 网页中取消“受保护”再删除。")
            } else {
                Text("将永久删除 \(backup.storage) 上 \(Format.shortDate(backup.ctime)) 的备份，无法恢复。")
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") {}
        } message: {
            Text(message ?? "")
        }
    }

    func load() async {
        let result = await connection.run(.datastoreAudit, on: nil) { client in
            try await client.backups(node: guest.node, vmid: guest.vmid)
        }
        loaded = true
        switch result {
        case .success(let list):
            backups = list
            error = nil
        case .failure(let failure):
            if case .failed(let text) = failure, text == ErrorText.message(for: PVEError.cancelled) { return }
            error = failure
        }
    }

    private func resolveMode(_ backup: BackupVolume) async {
        guard modes[backup.volid] == nil, let date = backup.ctime else { return }
        if let mode = try? await connection.client.backupMode(node: guest.node, vmid: guest.vmid, createdAt: date) {
            modes[backup.volid] = mode
        }
    }

    private func delete(_ backup: BackupVolume) async {
        let needs = [PermissionNeed(.datastoreAllocateSpace, on: PermissionNeed.storage(backup.storage))]
        await connection.loadPermissions(paths: needs.map(\.path))
        let missing = connection.missing(needs)
        guard missing.isEmpty else {
            message = String(localized: "无法删除备份：\(ServerConnection.describe(missing))")
            return
        }
        let result = await connection.run(.datastoreAllocateSpace, on: PermissionNeed.storage(backup.storage)) { client in
            try await client.deleteVolume(node: guest.node, storage: backup.storage, volid: backup.volid)
        }
        switch result {
        case .success(let upid):
            if let upid {
                onTask(TrackedTask(upid: upid, title: String(localized: "删除备份")))
            }
            await load()
        case .failure(let failure):
            message = failure.message
        }
    }
}

/// Time, size, storage and mode of one backup.
struct BackupRow: View {
    let backup: BackupVolume
    let mode: BackupMode?

    var body: some View {
        HStack(spacing: 12) {
            RowIcon(systemName: "archivebox")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Format.shortDate(backup.ctime))
                    .font(.body)
                    .monospacedDigit()
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                if let notes = backup.notes {
                    Text(verbatim: notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
            if backup.isProtected {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("受保护"))
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        [Format.bytes(backup.size), backup.storage, mode?.title ?? String(localized: "模式未知")].joined(separator: " · ")
    }
}

/// 「立即备份」 (`PVE.window.Backup`): storage, mode, protected, compression, notification
/// (+ e-mail for sendmail), prune, notes template, PBS change detection for CTs.
struct BackupNowView: View {
    let connection: ServerConnection
    let guest: GuestRef
    let onStarted: (TrackedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var storages: [NodeStorage] = []
    @State private var draft: BackupRequest
    @State private var retention: BackupRetention?
    @State private var defaultsApplied = false
    @State private var loadError: String?
    @State private var starting = false
    @State private var startError: String?

    init(connection: ServerConnection, guest: GuestRef, onStarted: @escaping (TrackedTask) -> Void) {
        self.connection = connection
        self.guest = guest
        self.onStarted = onStarted
        var request = BackupRequest(vmid: guest.vmid, storage: "")
        request.guestType = guest.type
        _draft = State(initialValue: request)
    }

    private var selected: NodeStorage? { storages.first { $0.storage == draft.storage } }

    private var needs: [PermissionNeed] {
        var list = [PermissionNeed(.vmBackup, on: guest.aclPath)]
        if !draft.storage.isEmpty { list.append(PermissionNeed(.datastoreAllocateSpace, on: PermissionNeed.storage(draft.storage))) }
        return list
    }

    var body: some View {
        let missing = connection.missing(needs)
        NavigationStack {
            Form {
                if let loadError {
                    Section { ErrorBanner(message: loadError) { Task { await loadStorages() } } }
                }
                Section {
                    Picker("存储", selection: $draft.storage) {
                        if draft.storage.isEmpty { Text("请选择").tag("") }
                        ForEach(storages) { storage in
                            Text(verbatim: storage.storage).tag(storage.storage)
                        }
                    }
                    Picker("模式", selection: $draft.mode) {
                        ForEach(BackupMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("受保护", isOn: $draft.isProtected)
                    if guest.type == .lxc && selected?.isPBS == true {
                        Picker("PBS 变更检测模式", selection: $draft.changeDetection) {
                            Text("默认").tag(PBSChangeDetectionMode.default)
                            Text("Data").tag(PBSChangeDetectionMode.data)
                            Text("Metadata").tag(PBSChangeDetectionMode.metadata)
                        }
                    }
                } footer: {
                    if guest.type == .lxc && selected?.isPBS == true {
                        Text("检测文件变化并切换容器备份到 Proxmox Backup Server 的归档编码格式。不适用于虚拟机备份。")
                    }
                }
                Section {
                    Picker("压缩", selection: $draft.compression) {
                        Text("无").tag(BackupCompression.none)
                        Text("LZO（快）").tag(BackupCompression.lzo)
                        Text("GZIP（好）").tag(BackupCompression.gzip)
                        Text("ZSTD（快且好）").tag(BackupCompression.zstd)
                    }
                    .disabled(selected?.isPBS == true)
                    Picker("通知", selection: $draft.notificationMode) {
                        Text("使用全局设置").tag(BackupNotificationMode.notificationSystem)
                        Text("使用 sendmail（旧版）").tag(BackupNotificationMode.legacySendmail)
                        Text("无").tag(BackupNotificationMode.none)
                    }
                    if draft.notificationMode == .legacySendmail {
                        TextField("发送邮件至", text: $draft.mailto, prompt: Text("无"))
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if retention?.offersPrune == true {
                        Toggle("清理旧备份", isOn: $draft.prune)
                    }
                } footer: {
                    if selected?.isPBS == true {
                        Text("Proxmox Backup Server 存储始终使用 ZSTD 压缩。")
                    }
                }
                if draft.prune, let retention, !retention.keeps.isEmpty {
                    Section("存储保留配置") {
                        ForEach(Array(retention.keeps.enumerated()), id: \.offset) { _, keep in
                            InfoRow(title: LocalizedStringKey(Self.keepTitle(keep.name)), value: String(keep.value))
                        }
                    }
                }
                Section {
                    TextField("备注", text: $draft.notes, axis: .vertical)
                        .lineLimit(2...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("备注")
                } footer: {
                    Text("可用的模板变量：\(NotesTemplate.variables.map { "{{\($0)}}" }.joined(separator: ", "))")
                }
                if let startError {
                    Section { ErrorBanner(message: startError) }
                }
                if !missing.isEmpty {
                    Section { MissingPermissionLabel(action: "备份", missing: missing) }
                }
            }
            .navigationTitle("立即备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("备份") { Task { await start() } }
                        .disabled(draft.storage.isEmpty || starting || !missing.isEmpty)
                        .accessibilityIdentifier("backup-start")
                }
            }
            .task { await loadStorages() }
            .onChange(of: draft.storage) { _, storage in
                Task { await applyDefaults(storage: storage) }
            }
        }
    }

    static func keepTitle(_ key: String) -> String {
        switch key {
        case "keep-last": return String(localized: "保留最近")
        case "keep-hourly": return String(localized: "保留每小时")
        case "keep-daily": return String(localized: "保留每日")
        case "keep-weekly": return String(localized: "保留每周")
        case "keep-monthly": return String(localized: "保留每月")
        default: return String(localized: "保留每年")
        }
    }

    private func loadStorages() async {
        do {
            storages = try await connection.client.nodeStorages(node: guest.node, content: "backup").filter(\.active)
            loadError = nil
            if draft.storage.isEmpty, let first = storages.first { draft.storage = first.storage }
            await connection.loadPermissions(paths: needs.map(\.path))
        } catch {
            connection.absorb(error)
            loadError = ErrorText.message(for: error)
        }
    }

    /// `GET /nodes/{node}/vzdump/defaults?storage=…`: notification, mode and notes once,
    /// retention for every storage, like the WebUI.
    private func applyDefaults(storage: String) async {
        guard !storage.isEmpty else { return }
        draft.storageIsPBS = selected?.isPBS == true
        if draft.storageIsPBS {
            draft.compression = .zstd
        }
        await connection.loadPermissions(path: PermissionNeed.storage(storage))
        guard let defaults = try? await connection.client.vzdumpDefaults(node: guest.node, storage: storage) else {
            retention = nil
            draft.prune = false
            return
        }
        if !defaultsApplied {
            defaultsApplied = true
            var mode = defaults.notificationMode ?? "auto"
            if mode == "auto" { mode = defaults.mailto != nil ? "legacy-sendmail" : "notification-system" }
            draft.notificationMode = BackupNotificationMode(rawValue: mode) ?? .notificationSystem
            if let mailto = defaults.mailto { draft.mailto = mailto }
            if let mode = defaults.mode.flatMap(BackupMode.init(rawValue:)) { draft.mode = mode }
            if let notes = defaults.notesTemplate, !notes.isEmpty { draft.notes = NotesTemplate.unescape(notes) }
        }
        retention = BackupRetention(defaults.pruneBackups)
        if retention?.offersPrune != true { draft.prune = false }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        draft.storageIsPBS = selected?.isPBS == true
        let request = draft
        let result = await connection.run(.vmBackup, on: guest.aclPath) { client in
            try await client.backup(node: guest.node, request)
        }
        switch result {
        case .success(let upid):
            onStarted(TrackedTask(upid: upid, title: String(localized: "备份 \(String(guest.vmid))")))
        case .failure(let error):
            startError = error.message
        }
    }
}

/// 「恢复」 (`PVE.window.Restore`): restore over the original guest (stopped, always confirmed)
/// or as a new guest (VMID from `/cluster/nextid`).
struct RestoreView: View {
    let connection: ServerConnection
    let node: String
    let backup: BackupVolume
    /// The guest the backup belongs to, when it exists on this node.
    let sourceGuest: GuestRef?
    let sourceName: String?
    let sourceIsStopped: Bool
    let onStarted: (TrackedTask) -> Void

    enum Destination: Hashable { case overwrite, new }

    @Environment(\.dismiss) private var dismiss
    @State private var destination: Destination = .new
    @State private var newVMID: Int?
    @State private var vmidFree: Bool?
    @State private var storages: [NodeStorage] = []
    @State private var storage = ""
    @State private var bandwidth: Int?
    @State private var unique = false
    @State private var start = false
    @State private var addToHA = false
    @State private var liveRestore = false
    @State private var allowMismatch = false
    @State private var identityMismatch = false
    @State private var privilege: RestoreRequest.PrivilegeLevel = .keep
    @State private var name = ""
    @State private var cores: Int?
    @State private var memory: Int?
    @State private var sockets: Int?
    @State private var summary: BackupConfigSummary?
    @State private var confirmOverwrite = false
    @State private var starting = false
    @State private var error: String?

    private var type: GuestType { backup.guestType ?? sourceGuest?.type ?? .qemu }
    private var canOverwrite: Bool { sourceGuest != nil }

    private var request: RestoreRequest? {
        let target: RestoreRequest.Target
        switch destination {
        case .overwrite:
            guard let sourceGuest else { return nil }
            target = .overwrite(vmid: sourceGuest.vmid)
        case .new:
            guard let newVMID, VMID.isValid(newVMID) else { return nil }
            target = .new(vmid: newVMID)
        }
        var request = RestoreRequest(volid: backup.volid, type: type, target: target)
        request.storage = storage.isEmpty ? nil : storage
        request.bandwidthLimit = bandwidth
        request.unique = unique
        request.start = start
        request.addToHA = addToHA
        request.liveRestore = liveRestore && backup.isPBS && type == .qemu
        request.allowIdentityMismatch = allowMismatch
        request.privilegeLevel = privilege
        request.name = name
        request.cores = cores
        request.memory = memory
        request.sockets = type == .qemu ? sockets : nil
        return request
    }

    private var needs: [PermissionNeed] {
        var list: [PermissionNeed] = []
        switch destination {
        case .overwrite:
            if let sourceGuest { list.append(PermissionNeed(.vmBackup, on: sourceGuest.aclPath)) }
        case .new:
            list.append(PermissionNeed(.vmAllocate, on: newVMID.map { PermissionNeed.vm($0) } ?? "/vms"))
        }
        if !storage.isEmpty { list.append(PermissionNeed(.datastoreAllocateSpace, on: PermissionNeed.storage(storage))) }
        return list
    }

    private var problem: String? {
        if destination == .overwrite && !sourceIsStopped {
            return String(localized: "覆盖原有 \(type == .qemu ? "虚拟机" : "容器") 前需要先将其停机。")
        }
        if destination == .new {
            guard let newVMID, VMID.isValid(newVMID) else { return String(localized: "VMID 须为 100–999999999 之间的整数") }
            if vmidFree == false { return String(localized: "VMID \(String(newVMID)) 已被使用") }
        }
        if type == .lxc && storage.isEmpty { return String(localized: "请选择目标存储") }
        if identityMismatch && destination == .overwrite && !allowMismatch {
            return String(localized: "备份与现有客户机的唯一 ID 不同，需要勾选“允许恢复其他客户机的备份”。")
        }
        if !name.isEmpty && !WizardValidation.isDNSName(name) { return String(localized: "名称无效") }
        return nil
    }

    var body: some View {
        let missing = connection.missing(needs)
        NavigationStack {
            Form {
                Section {
                    InfoRow(title: "来源", value: backup.volid, raw: backup.volid)
                    InfoRow(title: "时间", value: Format.shortDate(backup.ctime))
                    Picker("恢复到", selection: $destination) {
                        if canOverwrite {
                            Text("覆盖原 VMID \(String(sourceGuest?.vmid ?? 0))").tag(Destination.overwrite)
                        }
                        Text("新的\(type == .qemu ? "虚拟机" : "容器")").tag(Destination.new)
                    }
                    .accessibilityIdentifier("restore-destination")
                    if destination == .new {
                        OptionalIntField(title: type == .qemu ? "VM ID" : "CT ID", value: $newVMID)
                    }
                } footer: {
                    if destination == .overwrite {
                        Text(type == .lxc ? "将永久清除当前容器的数据，挂载点卷也会被清除。" : "将永久清除当前虚拟机的数据。")
                    }
                }
                Section {
                    Picker("目标存储", selection: $storage) {
                        if type == .qemu { Text("使用备份中的配置").tag("") }
                        ForEach(storages) { storage in
                            Text(verbatim: storage.storage).tag(storage.storage)
                        }
                    }
                    OptionalIntField(title: "带宽限制 (KiB/s)", value: $bandwidth, prompt: String(localized: "默认为目标存储的恢复限制"))
                    Toggle("唯一", isOn: $unique)
                    Toggle("恢复后启动", isOn: $start)
                        .disabled(liveRestore)
                    Toggle("添加到高可用", isOn: $addToHA)
                    if type == .qemu && backup.isPBS {
                        Toggle("实时恢复", isOn: $liveRestore)
                    }
                    if destination == .overwrite {
                        Toggle("允许恢复其他客户机的备份", isOn: $allowMismatch)
                    }
                    if type == .lxc {
                        Picker("特权级别", selection: $privilege) {
                            Text("来自备份").tag(RestoreRequest.PrivilegeLevel.keep)
                            Text("无特权").tag(RestoreRequest.PrivilegeLevel.unprivileged)
                            Text("特权").tag(RestoreRequest.PrivilegeLevel.privileged)
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“唯一”会自动生成新的唯一属性，例如 MAC 地址。带宽填 0 表示不限制。")
                        if liveRestore {
                            Text("注意：实时恢复过程中如果出现问题，虚拟机新写入的数据可能会丢失。")
                        }
                        if identityMismatch && destination == .overwrite {
                            Text("备份与现有客户机的唯一 ID 不同。").foregroundStyle(.orange)
                        }
                    }
                }
                Section("覆盖设置") {
                    LabeledContent(type == .lxc ? "主机名" : "名称") {
                        TextField(summary?.name ?? "", text: $name)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    OptionalIntField(title: "核心", value: $cores, prompt: summary?.cores)
                    OptionalIntField(title: "内存 (MiB)", value: $memory, prompt: summary?.memory)
                    if type == .qemu {
                        OptionalIntField(title: "CPU 插槽数", value: $sockets, prompt: summary?.sockets)
                    }
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.footnote) }
                }
                if let error {
                    Section { ErrorBanner(message: error) }
                }
                if !missing.isEmpty {
                    Section { MissingPermissionLabel(action: "恢复", missing: missing) }
                }
            }
            .navigationTitle("恢复备份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("恢复") {
                        if destination == .overwrite { confirmOverwrite = true } else { Task { await restore() } }
                    }
                    .disabled(request == nil || problem != nil || starting || !missing.isEmpty)
                    .accessibilityIdentifier("restore-start")
                }
            }
            .confirmationDialog("覆盖恢复", isPresented: $confirmOverwrite, titleVisibility: .visible) {
                Button("覆盖并恢复", role: .destructive) { Task { await restore() } }
            } message: {
                Text("\(sourceName ?? String(sourceGuest?.vmid ?? 0)) 的当前数据将被备份覆盖，且无法撤销。")
            }
            .task { await prepare() }
            .onChange(of: newVMID) { _, value in
                Task { await checkVMID(value) }
            }
            .onChange(of: liveRestore) { _, live in if live { start = false } }
        }
    }

    private func prepare() async {
        if newVMID == nil { newVMID = try? await connection.client.nextVMID() }
        let content = type == .lxc ? "rootdir" : "images"
        storages = (try? await connection.client.nodeStorages(node: node, content: content)) ?? []
        // CTs need a storage (the backend default `local` may not allow rootdir).
        if type == .lxc && storage.isEmpty {
            storage = storages.first(where: { $0.storage == backup.storage })?.storage ?? storages.first?.storage ?? ""
        }
        if let config = try? await connection.client.backupConfig(node: node, volid: backup.volid) {
            summary = config
            if type == .qemu && config.mappedStorages.contains(where: { storage in storage == nil || !storages.contains { $0.storage == storage } }) {
                // Not every storage of the backup exists here: a storage must be chosen.
                if storage.isEmpty { storage = storages.first?.storage ?? "" }
            }
            if let uid = config.uid, let sourceGuest, let current = await currentUID(sourceGuest), current != uid {
                identityMismatch = true
            }
        }
        var paths = needs.map(\.path)
        paths.append("/vms")
        await connection.loadPermissions(paths: paths)
        if let newVMID { await checkVMID(newVMID) }
    }

    /// The existing guest's unique ID (`uid` of its status), compared with the backup's.
    private func currentUID(_ guest: GuestRef) async -> String? {
        let status: JSONValue?
        switch guest.type {
        case .qemu: status = try? await connection.client.send(PVEAPI.GetNodesQemuStatusCurrent(node: guest.node, vmid: guest.vmid), as: JSONValue.self)
        case .lxc: status = try? await connection.client.send(PVEAPI.GetNodesLxcStatusCurrent(node: guest.node, vmid: guest.vmid), as: JSONValue.self)
        }
        guard case .object(let object)? = status else { return nil }
        return object["uid"]?.stringValue
    }

    private func checkVMID(_ value: Int?) async {
        guard let value, VMID.isValid(value) else { vmidFree = nil; return }
        vmidFree = try? await connection.client.isVMIDFree(value)
        await connection.loadPermissions(path: PermissionNeed.vm(value))
    }

    private func restore() async {
        guard let request else { return }
        starting = true
        defer { starting = false }
        let privilege: Privilege = destination == .overwrite ? .vmBackup : .vmAllocate
        let result = await connection.run(privilege, on: PermissionNeed.vm(request.target.vmid)) { client in
            try await client.restore(node: node, request)
        }
        switch result {
        case .success(let upid):
            onStarted(TrackedTask(upid: upid, title: String(localized: "恢复到 \(String(request.target.vmid))")))
        case .failure(let failure):
            error = failure.message
        }
    }
}
