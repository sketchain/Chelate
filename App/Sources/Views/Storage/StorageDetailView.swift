import PVEKit
import SwiftUI

/// Storage overview: usage, download actions and the content list grouped by type (browse only).
struct StorageDetailView: View {
    let connection: ServerConnection
    let node: String
    let storage: String

    enum ActiveSheet: Identifiable {
        case downloadURL
        case templates
        case task(TrackedTask)

        var id: String {
            switch self {
            case .downloadURL: return "download"
            case .templates: return "templates"
            case .task(let task): return task.id
            }
        }
    }

    @State private var status: StorageStatus?
    @State private var items: [StorageContentItem] = []
    @State private var error: ActionError?
    @State private var loaded = false
    @State private var sheet: ActiveSheet?

    private var aclPath: String { "/storage/\(storage)" }

    private var resource: ClusterResource? {
        connection.resources.first { $0.kind == .storage && $0.node == node && $0.storage == storage }
    }

    /// Content types the storage accepts (status first, cluster resource as fallback).
    private var contentTypes: Set<StorageContentType> {
        if let status, !status.content.isEmpty { return status.content }
        return StorageContentType.parseList(resource?.content)
    }

    private var downloadTypes: [StorageContentType] {
        StorageContentType.downloadable.filter { contentTypes.contains($0) }
    }

    var body: some View {
        let canDownload = connection.allows(.datastoreAllocateTemplate, on: aclPath)
        List {
            headerSection(canDownload: canDownload)
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看存储内容（需要 Datastore.Audit）")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            if !loaded && error == nil {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if loaded && items.isEmpty && error == nil {
                ContentUnavailableView("没有内容", systemImage: "tray")
            }
            ForEach(items.groupedByContent()) { group in
                Section {
                    ForEach(group.items) { item in
                        StorageContentRow(item: item)
                    }
                } header: {
                    Text(verbatim: Names.storageContent(group.content))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
        .navigationTitle(storage)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            await connection.loadPermissions(path: aclPath)
            await load()
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .downloadURL:
                DownloadURLView(connection: connection, node: node, storage: storage, contentTypes: downloadTypes) { task in
                    self.sheet = .task(task)
                }
            case .templates:
                ApplianceTemplatesView(
                    connection: connection,
                    node: node,
                    storage: storage,
                    downloaded: Set(items.filter { $0.contentType == .vztmpl }.map(\.fileName))
                ) { task in
                    self.sheet = .task(task)
                }
            case .task(let task):
                TaskMonitorSheet(connection: connection, task: task) {
                    Task { await load() }
                }
            }
        }
    }

    @ViewBuilder
    private func headerSection(canDownload: Bool) -> some View {
        let used = status?.used ?? resource?.disk
        let total = status?.total ?? resource?.maxdisk
        let fraction = status?.fraction ?? resource?.diskFraction
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(verbatim: storage)
                        .font(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    if let type = status?.type ?? resource?.plugintype {
                        Text(verbatim: (status?.shared ?? resource?.shared ?? false) ? "\(type) · \(String(localized: "共享"))" : type)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 12) {
                    Text(verbatim: Format.usage(used, total))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: Format.percent(fraction))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                ProgressView(value: min(max(fraction ?? 0, 0), 1))
                    .tint(tint(fraction))
            }
            .padding(.vertical, 4)
            if !downloadTypes.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        sheet = .downloadURL
                    } label: {
                        Label("从 URL 下载", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("storage-download-url")
                    if contentTypes.contains(.vztmpl) {
                        Button {
                            sheet = .templates
                        } label: {
                            Label("官方模板", systemImage: "shippingbox")
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("storage-templates")
                    }
                }
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
                .disabled(!canDownload)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
        } footer: {
            if !downloadTypes.isEmpty && !canDownload {
                NoPermissionLabel(text: "无权限下载（需要 Datastore.AllocateTemplate）")
            }
        }
    }

    private func tint(_ fraction: Double?) -> Color {
        guard let fraction else { return .gray }
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .orange }
        return .accentColor
    }

    private func load() async {
        let statusValue = await connection.run(.datastoreAudit, on: aclPath) { client in
            try await client.storageStatus(node: node, storage: storage)
        }
        let contentValue = await connection.run(.datastoreAudit, on: aclPath) { client in
            try await client.storageContent(node: node, storage: storage)
        }
        if case .success(let value) = statusValue { status = value }
        switch contentValue {
        case .success(let value):
            items = value
            error = nil
        case .failure(let failure):
            if case .failed(let message) = failure, message == ErrorText.message(for: PVEError.cancelled) { return }
            error = failure
        }
        loaded = true
    }
}

/// Two-line content row: fixed icon, file name (middle truncation), "size · date".
struct StorageContentRow: View {
    let item: StorageContentItem

    var body: some View {
        HStack(spacing: 12) {
            RowIcon(systemName: Names.storageContentIcon(item.content))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.fileName)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
            if item.isProtected {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("受保护"))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        var parts = [Format.bytes(item.size)]
        if let date = item.ctime {
            parts.append(Format.shortDate(date))
        } else if let vmid = item.vmid {
            parts.append("VMID \(vmid)")
        }
        return parts.joined(separator: " · ")
    }
}
