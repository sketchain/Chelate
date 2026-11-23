import PVEKit
import SwiftUI

/// `download-url` form: URL → `query-url-metadata` fills file name and size; optional checksum.
struct DownloadURLView: View {
    let connection: ServerConnection
    let node: String
    let storage: String
    /// Content types this storage accepts among the downloadable ones (ISO, CT template).
    let contentTypes: [StorageContentType]
    let onStarted: (TrackedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var content: StorageContentType = .iso
    @State private var url = ""
    @State private var filename = ""
    @State private var filenameEdited = false
    @State private var size: Double?
    @State private var mimetype: String?
    @State private var verifyCertificates = true
    @State private var checksumAlgorithm: ChecksumAlgorithm?
    @State private var checksum = ""
    @State private var querying = false
    @State private var queryError: String?
    @State private var starting = false
    @State private var startError: String?

    private var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var isValidURL: Bool {
        guard let components = URLComponents(string: trimmedURL), let scheme = components.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https" || scheme == "ftp") && !(components.host ?? "").isEmpty
    }

    private var filenameProblem: LocalizedStringKey? {
        let name = filename.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if name.contains("/") { return "文件名不能包含 /。" }
        switch content {
        case .iso:
            let lower = name.lowercased()
            if !(lower.hasSuffix(".iso") || lower.hasSuffix(".img")) { return "ISO 镜像的文件名须以 .iso 或 .img 结尾。" }
        case .vztmpl:
            let lower = name.lowercased()
            let ok = [".tar.gz", ".tar.xz", ".tar.zst", ".tar.bz2", ".tgz", ".tar"].contains { lower.hasSuffix($0) }
            if !ok { return "CT 模板的文件名须以 .tar.gz、.tar.xz 或 .tar.zst 等结尾。" }
        default:
            break
        }
        return nil
    }

    private var checksumMissing: Bool {
        checksumAlgorithm != nil && checksum.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canStart: Bool {
        isValidURL && !filename.trimmingCharacters(in: .whitespaces).isEmpty && filenameProblem == nil && !checksumMissing && !starting
    }

    var body: some View {
        NavigationStack {
            Form {
                if contentTypes.count > 1 {
                    Section {
                        Picker("内容类型", selection: $content) {
                            ForEach(contentTypes) { type in
                                Text(verbatim: Names.storageContent(type.rawValue)).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                    } footer: {
                        Text("第三方 CT 模板请选择「CT 模板」并填写真实的下载链接。")
                    }
                }
                Section {
                    TextField("下载链接（https://…）", text: $url, axis: .vertical)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...4)
                        .accessibilityIdentifier("download-url-field")
                    Toggle("验证证书", isOn: $verifyCertificates)
                } header: {
                    Text("URL")
                } footer: {
                    if let queryError {
                        Text(queryError).foregroundStyle(.red)
                    }
                }
                Section {
                    HStack(spacing: 12) {
                        Text("文件名")
                        TextField("文件名", text: Binding(
                            get: { filename },
                            set: { filename = $0; filenameEdited = true }
                        ))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("download-filename-field")
                    }
                    HStack(spacing: 12) {
                        Text("大小")
                        Spacer(minLength: 8)
                        if querying {
                            ProgressView()
                        } else {
                            Text(verbatim: size.map { Format.bytes($0) } ?? "–")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if let mimetype {
                        InfoRow(title: "类型", value: mimetype)
                    }
                } header: {
                    Text("文件")
                } footer: {
                    if let filenameProblem {
                        Text(filenameProblem).foregroundStyle(.red)
                    } else {
                        Text("输入链接后会自动查询文件名和大小，文件名可以修改。")
                    }
                }
                Section {
                    Picker("校验算法", selection: $checksumAlgorithm) {
                        Text("不校验").tag(ChecksumAlgorithm?.none)
                        ForEach(ChecksumAlgorithm.allCases) { algorithm in
                            Text(verbatim: algorithm.rawValue.uppercased()).tag(Optional(algorithm))
                        }
                    }
                    if checksumAlgorithm != nil {
                        TextField("校验和", text: $checksum, axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .lineLimit(1...4)
                    }
                } header: {
                    Text("校验和")
                }
                if let startError {
                    Section { ErrorBanner(message: startError) }
                }
            }
            .navigationTitle("从 URL 下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("下载") { Task { await start() } }
                            .disabled(!canStart)
                    }
                }
            }
            .onAppear {
                if !contentTypes.contains(content), let first = contentTypes.first { content = first }
                if DemoMode.isEnabled && url.isEmpty {
                    url = DemoData.sampleDownloadURL
                }
            }
            // Debounced metadata lookup whenever the URL or certificate check changes.
            .task(id: "\(trimmedURL)|\(verifyCertificates)") {
                await queryMetadata()
            }
        }
    }

    private func queryMetadata() async {
        guard isValidURL else {
            queryError = nil
            size = nil
            mimetype = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        querying = true
        defer { querying = false }
        let target = trimmedURL
        let verify = verifyCertificates
        let result = await connection.run(nil, on: nil) { client in
            try await client.queryURLMetadata(node: node, url: target, verifyCertificates: verify)
        }
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let metadata):
            queryError = nil
            size = metadata.size
            mimetype = metadata.mimetype
            if let name = metadata.filename, !filenameEdited || filename.isEmpty {
                filename = name
                filenameEdited = false
                guessContentType(from: name)
            } else if filename.isEmpty, let fallback = URL(string: target)?.lastPathComponent, !fallback.isEmpty, fallback != "/" {
                filename = fallback
                guessContentType(from: fallback)
            }
        case .failure(let failure):
            if case .failed(let message) = failure, message == ErrorText.message(for: PVEError.cancelled) { return }
            queryError = String(localized: "无法获取文件信息：\(failure.message)")
            size = nil
            mimetype = nil
            if filename.isEmpty, let fallback = URL(string: target)?.lastPathComponent, !fallback.isEmpty, fallback != "/" {
                filename = fallback
            }
        }
    }

    private func guessContentType(from name: String) {
        let lower = name.lowercased()
        if (lower.hasSuffix(".iso") || lower.hasSuffix(".img")), contentTypes.contains(.iso) {
            content = .iso
        } else if lower.contains(".tar"), contentTypes.contains(.vztmpl) {
            content = .vztmpl
        }
    }

    private func start() async {
        starting = true
        defer { starting = false }
        let request = DownloadURLRequest(
            url: trimmedURL,
            content: content,
            filename: filename.trimmingCharacters(in: .whitespaces),
            checksum: checksumAlgorithm == nil ? nil : checksum,
            checksumAlgorithm: checksumAlgorithm,
            verifyCertificates: verifyCertificates
        )
        let result = await connection.run(.datastoreAllocateTemplate, on: "/storage/\(storage)") { client in
            try await client.downloadURL(node: node, storage: storage, request)
        }
        switch result {
        case .success(let upid):
            onStarted(TrackedTask(upid: upid, title: String(localized: "下载 \(request.filename)")))
        case .failure(let failure):
            startError = failure.message
        }
    }
}
