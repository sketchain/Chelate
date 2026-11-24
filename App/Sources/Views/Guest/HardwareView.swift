import PVEKit
import SwiftUI

/// 「硬件」: processor (VM cores + sockets, CT cores), memory (VM memory + ballooning minimum,
/// CT memory + swap) and growing disks. Values changed on a running guest that only apply after
/// a restart are read from the pending config and marked 「重启后生效」.
struct HardwareView: View {
    let connection: ServerConnection
    let guest: GuestRef

    enum Sheet: Identifiable {
        case processor, memory, resize(GuestDisk)
        var id: String {
            switch self {
            case .processor: return "cpu"
            case .memory: return "memory"
            case .resize(let disk): return disk.key
            }
        }
    }

    @State private var hardware: GuestHardware?
    @State private var error: ActionError?
    @State private var sheet: Sheet?
    @State private var tracked: TrackedTask?
    @State private var message: String?

    var body: some View {
        let cpuMissing = connection.missing([PermissionNeed(.vmConfigCPU, on: guest.aclPath)])
        let memoryMissing = connection.missing([PermissionNeed(.vmConfigMemory, on: guest.aclPath)])
        let diskMissing = connection.missing([PermissionNeed(.vmConfigDisk, on: guest.aclPath)])
        List {
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看硬件配置（需要 VM.Audit）")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            if let hardware {
                Section {
                    row("核心", value: "\(hardware.cores)", key: "cores", in: hardware)
                    if guest.type == .qemu {
                        row("CPU 插槽数", value: "\(hardware.sockets)", key: "sockets", in: hardware)
                        InfoRow(title: "核心总数", value: "\(hardware.cores * hardware.sockets)")
                    }
                    Button("修改处理器") { sheet = .processor }
                        .disabled(!cpuMissing.isEmpty)
                        .accessibilityIdentifier("hardware-edit-cpu")
                } header: {
                    Text("处理器")
                } footer: {
                    MissingPermissionLabel(action: "修改处理器", missing: cpuMissing)
                }
                Section {
                    row("内存", value: mib(hardware.memory), key: "memory", in: hardware)
                    if guest.type == .qemu {
                        row("最小内存", value: balloonText(hardware), key: "balloon", in: hardware)
                    } else {
                        row("Swap", value: mib(hardware.swap), key: "swap", in: hardware)
                    }
                    Button("修改内存") { sheet = .memory }
                        .disabled(!memoryMissing.isEmpty)
                        .accessibilityIdentifier("hardware-edit-memory")
                } header: {
                    Text("内存")
                } footer: {
                    MissingPermissionLabel(action: "修改内存", missing: memoryMissing)
                }
                Section {
                    if hardware.disks.isEmpty {
                        Text("没有可扩容的磁盘").foregroundStyle(.secondary)
                    }
                    ForEach(hardware.disks) { disk in
                        Button { sheet = .resize(disk) } label: {
                            HStack(spacing: 12) {
                                RowIcon(systemName: "internaldrive")
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(verbatim: disk.key).font(.body)
                                        if hardware.isPending(disk.key) { PendingBadge() }
                                    }
                                    Text(verbatim: disk.volume)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                                Spacer(minLength: 8)
                                Text(verbatim: Format.bytes(disk.size))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!diskMissing.isEmpty)
                    }
                } header: {
                    Text("磁盘")
                } footer: {
                    if !diskMissing.isEmpty {
                        MissingPermissionLabel(action: "扩容磁盘", missing: diskMissing)
                    } else if !hardware.disks.isEmpty {
                        Text("点按磁盘扩容。磁盘只能扩大，不能缩小。")
                    }
                }
            } else if error == nil {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle("硬件")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            await connection.loadPermissions(path: guest.aclPath)
            await load()
        }
        .sheet(item: $sheet) { sheet in
            if let hardware {
                switch sheet {
                case .processor:
                    ProcessorEditView(guest: guest, hardware: hardware) { change in await apply(change, privilege: .vmConfigCPU) }
                case .memory:
                    MemoryEditView(guest: guest, hardware: hardware) { change in await apply(change, privilege: .vmConfigMemory) }
                case .resize(let disk):
                    DiskResizeView(disk: disk) { resize in await resizeDisk(resize) }
                }
            }
        }
        .sheet(item: $tracked) { task in
            TaskMonitorSheet(connection: connection, task: task) { Task { await load() } }
        }
        .alert("操作未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") {}
        } message: {
            Text(message ?? "")
        }
    }

    private func row(_ title: LocalizedStringKey, value: String, key: String, in hardware: GuestHardware) -> some View {
        HStack(spacing: 12) {
            Text(title).layoutPriority(1)
            if hardware.isPending(key) { PendingBadge() }
            Spacer(minLength: 8)
            Text(verbatim: value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func mib(_ value: Int) -> String { Format.bytes(Double(value) * 1_048_576) }

    private func balloonText(_ hardware: GuestHardware) -> String {
        guard let balloon = hardware.balloon else { return mib(hardware.memory) }
        return balloon == 0 ? String(localized: "已关闭 Ballooning") : mib(balloon)
    }

    private func load() async {
        let result = await connection.run(.vmAudit, on: guest.aclPath) { client in
            try await client.pendingConfig(guest)
        }
        switch result {
        case .success(let pending):
            hardware = GuestHardware(type: guest.type, pending: pending)
            error = nil
        case .failure(let failure):
            error = failure
        }
    }

    /// Returns an error message, or nil on success.
    private func apply(_ change: HardwareChange, privilege: Privilege) async -> String? {
        let result = await connection.run(privilege, on: guest.aclPath) { client in
            try await client.updateHardware(guest, change)
        }
        switch result {
        case .success:
            sheet = nil
            await load()
            return nil
        case .failure(let failure):
            return failure.message
        }
    }

    private func resizeDisk(_ resize: DiskResize) async -> String? {
        let result = await connection.run(.vmConfigDisk, on: guest.aclPath) { client in
            try await client.resizeDisk(guest, resize)
        }
        switch result {
        case .success(let upid):
            sheet = nil
            if let upid {
                tracked = TrackedTask(upid: upid, title: String(localized: "扩容 \(resize.disk.key)"))
            } else {
                await load()
            }
            return nil
        case .failure(let failure):
            return failure.message
        }
    }
}

struct PendingBadge: View {
    var body: some View {
        Text("重启后生效")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .accessibilityIdentifier("pending-badge")
    }
}

struct ProcessorEditView: View {
    let guest: GuestRef
    let hardware: GuestHardware
    let onSave: (HardwareChange) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var cores = 1
    @State private var sockets = 1
    @State private var saving = false
    @State private var error: String?

    private var change: HardwareChange {
        guest.type == .qemu ? HardwareChange(cores: cores, sockets: sockets) : HardwareChange(cores: cores)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $cores, in: 1...(guest.type == .qemu ? 256 : 8192)) {
                        LabeledContent("核心", value: "\(cores)")
                    }
                    if guest.type == .qemu {
                        Stepper(value: $sockets, in: 1...4) {
                            LabeledContent("CPU 插槽数", value: "\(sockets)")
                        }
                        LabeledContent("核心总数", value: "\(cores * sockets)")
                    }
                } footer: {
                    Text("运行中修改时，部分设置要在重启后才生效。")
                }
                if let error {
                    Section { ErrorBanner(message: error) }
                }
            }
            .navigationTitle("处理器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            saving = true
                            error = await onSave(change)
                            saving = false
                        }
                    }
                    .disabled(saving || !change.isValid || (cores == hardware.cores && sockets == hardware.sockets))
                }
            }
            .onAppear {
                cores = hardware.cores
                sockets = hardware.sockets
            }
        }
        .presentationDetents([.medium])
    }
}

struct MemoryEditView: View {
    let guest: GuestRef
    let hardware: GuestHardware
    let onSave: (HardwareChange) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var memory = 512
    @State private var ballooning = true
    @State private var balloon = 512
    @State private var swap = 512
    @State private var saving = false
    @State private var error: String?

    private var change: HardwareChange {
        if guest.type == .qemu {
            return HardwareChange(memory: memory, balloon: ballooning ? balloon : 0)
        }
        return HardwareChange(memory: memory, swap: swap)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    IntField(title: "内存 (MiB)", value: $memory)
                    if guest.type == .qemu {
                        Toggle("Ballooning 设备", isOn: $ballooning)
                        if ballooning {
                            IntField(title: "最小内存 (MiB)", value: $balloon)
                        }
                    } else {
                        IntField(title: "Swap (MiB)", value: $swap)
                    }
                } footer: {
                    if guest.type == .qemu && ballooning && balloon > memory {
                        Text("最小内存不能大于内存。").foregroundStyle(.red)
                    } else {
                        Text("运行中修改时，部分设置要在重启后才生效。")
                    }
                }
                if let error {
                    Section { ErrorBanner(message: error) }
                }
            }
            .navigationTitle("内存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            saving = true
                            error = await onSave(change)
                            saving = false
                        }
                    }
                    .disabled(saving || !change.isValid)
                }
            }
            .onAppear {
                memory = hardware.memory
                swap = hardware.swap
                balloon = hardware.balloon.map { $0 == 0 ? hardware.memory : $0 } ?? hardware.memory
                ballooning = hardware.balloon != 0
            }
        }
        .presentationDetents([.medium])
    }
}

/// Grow a disk by an increment or to a target size; the new size is confirmed before submitting.
struct DiskResizeView: View {
    let disk: GuestDisk
    let onResize: (DiskResize) async -> String?
    @Environment(\.dismiss) private var dismiss

    enum Mode: Hashable { case increment, target }
    @State private var mode: Mode = .increment
    @State private var gib: Double?
    @State private var confirming = false
    @State private var saving = false
    @State private var error: String?

    private var resize: DiskResize? {
        guard let gib else { return nil }
        let value = DiskResize(disk: disk, input: mode == .increment ? .increment(gib: gib) : .target(gib: gib))
        return value.isValid ? value : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("磁盘", value: disk.key)
                    LabeledContent("当前大小", value: Format.bytes(disk.size))
                    Picker("输入方式", selection: $mode) {
                        Text("增加").tag(Mode.increment)
                        Text("目标大小").tag(Mode.target)
                    }
                    .pickerStyle(.segmented)
                    OptionalDoubleField(title: mode == .increment ? "增加 (GiB)" : "目标大小 (GiB)", value: $gib)
                    if let resize, let size = resize.newSize {
                        LabeledContent("新大小", value: Format.bytes(size))
                    }
                } footer: {
                    if gib != nil && resize == nil {
                        Text("磁盘只能扩大：新大小必须大于当前大小。").foregroundStyle(.red)
                    } else {
                        Text("扩容后还需要在客户机内扩展分区和文件系统。")
                    }
                }
                if let error {
                    Section { ErrorBanner(message: error) }
                }
            }
            .navigationTitle("扩容磁盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("扩容") { confirming = true }
                        .disabled(resize == nil || saving)
                }
            }
            .confirmationDialog("确认扩容", isPresented: $confirming, titleVisibility: .visible) {
                Button("扩容到 \(Format.bytes(resize?.newSize))") {
                    guard let resize else { return }
                    Task {
                        saving = true
                        error = await onResize(resize)
                        saving = false
                    }
                }
            } message: {
                Text("\(disk.key) 将从 \(Format.bytes(disk.size)) 扩大到 \(Format.bytes(resize?.newSize))。磁盘无法再缩小。")
            }
        }
        .presentationDetents([.medium, .large])
    }
}
