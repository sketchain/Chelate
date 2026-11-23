import PVEKit
import SwiftUI
import UIKit

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
    @State private var copyCount = 0
    @State private var showCopied = false

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
                        .accessibilityIdentifier("template-row")
                        // Anchored on the row so the dialog points at the tapped template.
                        .confirmationDialog(
                            "下载模板",
                            isPresented: Binding(
                                get: { pending?.id == template.id },
                                set: { if !$0, pending?.id == template.id { pending = nil } }
                            ),
                            titleVisibility: .visible
                        ) {
                            actions(for: template)
                        } message: {
                            Text(verbatim: Self.breakableFileName(template.template))
                        }
                        .contextMenu {
                            actions(for: template)
                        }
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
            .overlay(alignment: .bottom) {
                if showCopied {
                    CopiedToast()
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: showCopied)
            .task(id: copyCount) {
                guard copyCount > 0 else { return }
                showCopied = true
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                showCopied = false
            }
        }
    }

    /// Shared by the confirmation dialog and the context menu.
    @ViewBuilder
    private func actions(for template: ApplianceTemplate) -> some View {
        Button("下载到 \(storage)", systemImage: "arrow.down.circle") {
            Task { await download(template) }
        }
        if let location = template.location, !location.isEmpty {
            Button("复制下载链接", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = location
                copyCount += 1
            }
        }
    }

    /// Inserts zero-width spaces after `-`, `_` and `.` so the name wraps only at separators.
    static func breakableFileName(_ name: String) -> String {
        var result = ""
        for character in name {
            result.append(character)
            if character == "-" || character == "_" || character == "." {
                result.append("\u{200B}")
            }
        }
        return result
    }

    private func load() async {
        let result = await connection.run(nil, on: nil) { client in
            try await client.applianceTemplates(node: node)
        }
        loaded = true
        switch result {
        case .success(let list):
            templates = list.sorted { lhs, rhs in
                let order = (lhs.headline ?? lhs.template).localizedStandardCompare(rhs.headline ?? rhs.template)
                if order != .orderedSame { return order == .orderedAscending }
                return (lhs.architecture ?? "") < (rhs.architecture ?? "")
            }
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
        // 「13.6-1 · amd64 · 系统」: the architecture tells same-named templates apart.
        [template.version, template.architecture, Names.templateSection(template.section ?? "")]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// Short confirmation after copying.
struct CopiedToast: View {
    var body: some View {
        Label("已复制", systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .accessibilityAddTraits(.isStaticText)
    }
}
