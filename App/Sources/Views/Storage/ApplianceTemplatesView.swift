import PVEKit
import SwiftUI

/// Official CT templates (`aplinfo`), filterable by section and searchable; tapping one downloads
/// it to the current storage.
struct ApplianceTemplatesView: View {
    let connection: ServerConnection
    let node: String
    let storage: String
    /// File names of templates already on the storage.
    let downloaded: Set<String>
    let onStarted: (TrackedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var templates: [ApplianceTemplate] = []
    @State private var error: ActionError?
    @State private var loaded = false
    @State private var section: String?
    @State private var query = ""
    @State private var pending: ApplianceTemplate?
    @State private var startError: String?

    private var filtered: [ApplianceTemplate] {
        templates
            .filter { section == nil || $0.section == section }
            .filter { $0.matches(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if templates.sections.count > 1 {
                    Section {
                        Picker("分类", selection: $section) {
                            Text("全部").tag(String?.none)
                            ForEach(templates.sections, id: \.self) { section in
                                Text(verbatim: Names.templateSection(section)).tag(Optional(section))
                            }
                        }
                    }
                }
                if let error {
                    Section {
                        if error.isForbidden {
                            NoPermissionLabel(text: "无权限查看模板列表")
                        } else {
                            ErrorBanner(message: error.message) { Task { await load() } }
                        }
                    }
                }
                if let startError {
                    Section { ErrorBanner(message: startError) }
                }
                if !loaded && error == nil {
                    Section { HStack { Spacer(); ProgressView(); Spacer() } }
                } else if loaded && filtered.isEmpty && error == nil {
                    ContentUnavailableView.search(text: query)
                }
                Section {
                    ForEach(filtered) { template in
                        Button {
                            pending = template
                        } label: {
                            ApplianceTemplateRow(template: template, isDownloaded: downloaded.contains(template.template))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("官方模板")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("搜索模板"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .confirmationDialog(
                "下载模板",
                isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                titleVisibility: .visible,
                presenting: pending
            ) { template in
                Button("下载到 \(storage)") {
                    Task { await download(template) }
                }
            } message: { template in
                Text(verbatim: template.template)
            }
        }
    }

    private func load() async {
        let result = await connection.run(nil, on: nil) { client in
            try await client.applianceTemplates(node: node)
        }
        loaded = true
        switch result {
        case .success(let list):
            templates = list.sorted { ($0.headline ?? $0.template).localizedStandardCompare($1.headline ?? $1.template) == .orderedAscending }
            error = nil
        case .failure(let failure):
            if case .failed(let message) = failure, message == ErrorText.message(for: PVEError.cancelled) { return }
            error = failure
        }
    }

    private func download(_ template: ApplianceTemplate) async {
        let result = await connection.run(.datastoreAllocateTemplate, on: "/storage/\(storage)") { client in
            try await client.downloadApplianceTemplate(node: node, storage: storage, template: template.template)
        }
        switch result {
        case .success(let upid):
            onStarted(TrackedTask(upid: upid, title: String(localized: "下载 \(template.headline ?? template.template)")))
        case .failure(let failure):
            startError = failure.message
        }
    }
}

struct ApplianceTemplateRow: View {
    let template: ApplianceTemplate
    let isDownloaded: Bool

    var body: some View {
        HStack(spacing: 12) {
            RowIcon(systemName: "shippingbox")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: template.headline ?? template.package ?? template.template)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
            if isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(Text("已下载"))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var detail: String {
        [template.version, template.os, Names.templateSection(template.section ?? "")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
