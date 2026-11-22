import PVEKit
import SwiftUI

struct ServerEditView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let original: ServerConfig
    let isNew: Bool

    @State private var config = ServerConfig()
    @State private var portText = "8006"
    @State private var tokenSecret = ""
    @State private var hasStoredSecret = false
    @State private var resetPin = false

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("名称（可选）", text: $config.name)
                    TextField("主机名或 IP", text: $config.host)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口", text: $portText)
                        .keyboardType(.numberPad)
                }

                Section {
                    Picker("认证方式", selection: $config.authMethod) {
                        Text("账号密码").tag(ServerConfig.AuthMethod.password)
                        Text("API Token").tag(ServerConfig.AuthMethod.apiToken)
                    }
                    .pickerStyle(.segmented)

                    switch config.authMethod {
                    case .password:
                        TextField("用户名", text: $config.username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Realm", text: $config.realm)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    case .apiToken:
                        TextField("用户（含 realm，如 root@pam）", text: $config.tokenUserID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: config.tokenUserID) { _, newValue in
                                // Accept a pasted full token id "user@realm!tokenid".
                                if let split = APIToken.split(fullTokenID: newValue) {
                                    config.tokenUserID = split.userID
                                    config.tokenID = split.tokenID
                                }
                            }
                        TextField("Token ID", text: $config.tokenID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField(hasStoredSecret ? "Secret（留空则不修改）" : "Secret", text: $tokenSecret)
                    }
                } header: {
                    Text("认证")
                } footer: {
                    switch config.authMethod {
                    case .password:
                        Text("密码在连接时输入，可选择保存到钥匙串。Realm 默认为 pam（Linux PAM），PVE 内置用户为 pve。")
                    case .apiToken:
                        Text("Token 在“数据中心 › 权限 › API Token”中创建。启用“权限分离”的 Token 需要单独授予权限。用 Token 打开节点 Shell 时需要再输入一次 Linux 账号密码。")
                    }
                }

                if let pin = config.pinnedFingerprint {
                    Section {
                        Text(pin.description)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Toggle("清除已信任的证书指纹", isOn: $resetPin)
                    } header: {
                        Text("已信任的证书")
                    } footer: {
                        Text("清除后下次连接会重新校验证书。")
                    }
                }
            }
            .navigationTitle(isNew ? "添加服务器" : "编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear {
                config = original
                portText = String(original.port)
                hasStoredSecret = model.keychain.string(for: original.id, .tokenSecret) != nil
            }
        }
    }

    private var port: Int? {
        Int(portText.trimmingCharacters(in: .whitespaces))
    }

    private var isValid: Bool {
        guard let port else { return false }
        guard ServerEndpoint(host: config.host, port: port).isValid else { return false }
        switch config.authMethod {
        case .password:
            return !config.username.trimmingCharacters(in: .whitespaces).isEmpty
        case .apiToken:
            return config.tokenUserID.contains("@")
                && !config.tokenID.trimmingCharacters(in: .whitespaces).isEmpty
                && (hasStoredSecret || !tokenSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func save() {
        guard let port else { return }
        var result = config
        result.host = config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.port = port
        result.name = config.name.trimmingCharacters(in: .whitespaces)
        result.username = config.username.trimmingCharacters(in: .whitespaces)
        result.realm = config.realm.trimmingCharacters(in: .whitespaces).isEmpty ? "pam" : config.realm.trimmingCharacters(in: .whitespaces)
        result.tokenUserID = config.tokenUserID.trimmingCharacters(in: .whitespaces)
        result.tokenID = config.tokenID.trimmingCharacters(in: .whitespaces)
        if resetPin { result.pinnedFingerprint = nil }
        let secret = tokenSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        model.save(result, tokenSecret: secret.isEmpty ? nil : secret)
        dismiss()
    }
}
