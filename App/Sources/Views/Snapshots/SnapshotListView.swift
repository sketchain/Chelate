import PVEKit
import SwiftUI

struct SnapshotListView: View {
    let connection: ServerConnection
    let guest: GuestRef

    @State private var snapshots: [Snapshot] = []
    @State private var currentParent: String?
    @State private var error: ActionError?
    @State private var loaded = false
    @State private var showCreate = false
    @State private var rollbackTarget: Snapshot?
    @State private var deleteTarget: Snapshot?
    @State private var actionMessage: String?
    @State private var tracked: TrackedTask?

    var body: some View {
        let canSnapshot = connection.allows(.vmSnapshot, on: guest.aclPath)
        let canRollback = connection.allows(.vmSnapshotRollback, on: guest.aclPath)
        List {
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看快照")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            if loaded && snapshots.isEmpty && error == nil {
                ContentUnavailableView("没有快照", systemImage: "camera.on.rectangle", description: Text("点右上角 + 创建第一个快照。"))
            }
            Section {
                ForEach(snapshots) { snapshot in
                    SnapshotRow(snapshot: snapshot, isCurrentParent: snapshot.name == currentParent)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("删除", systemImage: "trash", role: .destructive) { deleteTarget = snapshot }
                                .disabled(!canSnapshot)
                            Button("回滚", systemImage: "arrow.uturn.backward") { rollbackTarget = snapshot }
                                .tint(.orange)
                                .disabled(!canRollback)
                        }
                        .contextMenu {
                            Button("回滚到此快照", systemImage: "arrow.uturn.backward") { rollbackTarget = snapshot }
                                .disabled(!canRollback)
                            Button("删除快照", systemImage: "trash", role: .destructive) { deleteTarget = snapshot }
                                .disabled(!canSnapshot)
                        }
                }
            } footer: {
                if !snapshots.isEmpty {
                    if !canSnapshot && !canRollback {
                        NoPermissionLabel(text: "无权限管理快照（需要 VM.Snapshot）")
                    } else {
                        Text("左滑或长按快照可回滚或删除。")
                    }
                }
            }
        }
        .navigationTitle("快照")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("创建快照", systemImage: "plus") { showCreate = true }
                    .disabled(!canSnapshot)
            }
        }
        .refreshable { await load() }
        .task {
            await connection.loadPermissions(path: guest.aclPath)
            await load()
        }
        .sheet(isPresented: $showCreate) {
            CreateSnapshotView(guest: guest) { name, description, includeRAM in
                showCreate = false
                Task {
                    await run(.vmSnapshot, title: String(localized: "创建快照 \(name)")) { client in
                        try await client.createSnapshot(guest, name: name, description: description, includeRAM: includeRAM)
                    }
                }
            }
        }
        .confirmationDialog(
            "回滚快照",
            isPresented: Binding(get: { rollbackTarget != nil }, set: { if !$0 { rollbackTarget = nil } }),
            titleVisibility: .visible,
            presenting: rollbackTarget
        ) { snapshot in
            Button("回滚到“\(snapshot.name)”", role: .destructive) {
                Task {
                    await run(.vmSnapshotRollback, title: String(localized: "回滚到 \(snapshot.name)")) { client in
                        try await client.rollbackSnapshot(guest, name: snapshot.name)
                    }
                }
            }
        } message: { snapshot in
            Text("当前状态将被快照“\(snapshot.name)”覆盖，此后的所有改动都会丢失，且无法撤销。")
        }
        .confirmationDialog(
            "删除快照",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible,
            presenting: deleteTarget
        ) { snapshot in
            Button("删除“\(snapshot.name)”", role: .destructive) {
                Task {
                    await run(.vmSnapshot, title: String(localized: "删除快照 \(snapshot.name)")) { client in
                        try await client.deleteSnapshot(guest, name: snapshot.name)
                    }
                }
            }
        } message: { snapshot in
            Text("快照“\(snapshot.name)”将被永久删除，无法恢复。")
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

    private func load() async {
        let result = await connection.run(.vmAudit, on: guest.aclPath) { client in
            try await client.snapshots(guest)
        }
        loaded = true
        switch result {
        case .success(let list):
            snapshots = list.realSnapshots
            currentParent = list.first(where: \.isCurrent)?.parent
            error = nil
        case .failure(let failure):
            error = failure
        }
    }

    private func run(_ privilege: Privilege, title: String, _ operation: (PVEClient) async throws -> String) async {
        let result = await connection.run(privilege, on: guest.aclPath, operation)
        switch result {
        case .success(let upid):
            tracked = TrackedTask(upid: upid, title: title)
        case .failure(let error):
            actionMessage = error.message
        }
    }
}

struct SnapshotRow: View {
    let snapshot: Snapshot
    let isCurrentParent: Bool
    @ScaledMetric(relativeTo: .body) private var iconWidth = RowMetrics.iconWidth

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "camera")
                .foregroundStyle(.secondary)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: snapshot.name)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if snapshot.vmstate {
                        badge("含内存", color: .blue)
                    }
                    if isCurrentParent {
                        badge("当前位置", color: .green)
                    }
                }
                if let date = snapshot.snaptime {
                    Text(verbatim: Format.shortDate(date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if let description = snapshot.description {
                    Text(verbatim: description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: LocalizedStringKey, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }
}

struct CreateSnapshotView: View {
    let guest: GuestRef
    let onCreate: (String, String?, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var includeRAM = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("描述（可选）", text: $description, axis: .vertical)
                        .lineLimit(2...5)
                    if guest.type == .qemu {
                        Toggle("包含内存状态", isOn: $includeRAM)
                    }
                } footer: {
                    if !name.isEmpty && !Snapshot.isValidName(name) {
                        Text("名称须以英文字母开头，只能包含字母、数字、- 和 _，最长 40 个字符。")
                            .foregroundStyle(.red)
                    } else if guest.type == .qemu {
                        Text("包含内存状态时，回滚后虚拟机会恢复到拍快照时的运行状态，但快照更慢、占用更多空间。")
                    }
                }
            }
            .navigationTitle("创建快照")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
                        onCreate(name, text.isEmpty ? nil : text, includeRAM)
                    }
                    .disabled(!Snapshot.isValidName(name))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
