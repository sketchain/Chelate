import PVEKit
import SwiftUI
import UIKit

/// Settings › 服务器 › <server>: connection info, certificate pin, delete.
struct ServerSettingsView: View {
    let serverID: UUID

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var editing: ServerConfig?
    @State private var confirmingForget = false
    @State private var confirmingDelete = false
    @State private var copied = false

    var body: some View {
        if let server = model.server(serverID) {
            content(server)
        } else {
            ContentUnavailableView("服务器已删除", systemImage: "server.rack")
        }
    }

    private func content(_ server: ServerConfig) -> some View {
        List {
            Section("连接") {
                InfoRow(title: "地址", value: "\(server.host):\(server.port)")
                InfoRow(title: "认证方式", value: server.authMethod == .apiToken ? "API Token" : String(localized: "账号密码"))
                InfoRow(title: "账号", value: server.authIDDescription)
                Button {
                    editing = server
                } label: {
                    Label("编辑连接信息", systemImage: "pencil")
                }
                .accessibilityIdentifier("server-edit")
            }

            Section {
                if let pin = server.pinnedFingerprint {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SHA-256")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: pin.description)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("server-fingerprint")
                    }
                    .padding(.vertical, 2)
                    Button {
                        UIPasteboard.general.string = pin.description
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制指纹", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        confirmingForget = true
                    } label: {
                        Label("忘记证书", systemImage: "xmark.seal")
                    }
                } else {
                    Text("使用系统信任的证书。连接到自签名证书的服务器时，会显示指纹由你确认。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("证书")
            } footer: {
                if server.pinnedFingerprint != nil {
                    Text("已信任此证书。忘记后，下次连接会重新校验证书并请你确认。")
                }
            }

            Section {
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Label("删除服务器", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(server.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { config in
            ServerEditView(original: config, isNew: false)
        }
        .confirmationDialog("忘记证书", isPresented: $confirmingForget, titleVisibility: .visible) {
            Button("忘记证书", role: .destructive) {
                model.forgetCertificate(server.id)
                copied = false
            }
        } message: {
            Text("下次连接“\(server.displayName)”时需要重新确认证书。")
        }
        .confirmationDialog("删除服务器", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("删除“\(server.displayName)”", role: .destructive) {
                model.delete(server.id)
                dismiss()
            }
        } message: {
            Text("将同时删除保存在钥匙串中的凭据。")
        }
    }
}
