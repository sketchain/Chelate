import PVEKit
import SwiftUI

/// Shows the content once the connection is ready; otherwise login, errors or progress.
/// Also hosts the TFA and certificate prompts, which can appear at any time (ticket renewal).
struct ConnectionGate<Content: View>: View {
    @Bindable var connection: ServerConnection
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            switch connection.state {
            case .ready:
                content()
            case .idle, .connecting:
                ProgressView("正在连接 \(connection.config.displayName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsLogin(let message):
                LoginForm(connection: connection, message: message)
            case .failed(let message):
                ContentUnavailableView {
                    Label("连接失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") { Task { await connection.connect() } }
                        .buttonStyle(.borderedProminent)
                    if connection.certificateIssue != nil {
                        Button("查看证书") { certificateDismissed = false }
                    }
                }
            }
        }
        .navigationTitle(connection.config.displayName)
        .task {
            if connection.state == .idle {
                await connection.connect()
            }
        }
        .sheet(item: Binding(
            get: { connection.tfaPrompt },
            set: { newValue in if newValue == nil, connection.tfaPrompt != nil { connection.answerTFA(nil) } }
        )) { prompt in
            TFASheet(prompt: prompt) { response in
                connection.answerTFA(response)
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: Binding(
            get: { connection.certificateIssue != nil && !certificateDismissed },
            set: { if !$0 { certificateDismissed = true } }
        )) {
            if let issue = connection.certificateIssue {
                CertificateSheet(issue: issue) { fingerprint in
                    connection.trustCertificate(fingerprint)
                    Task { await connection.connect() }
                } onCancel: {
                    certificateDismissed = true
                }
            }
        }
        .onChange(of: connection.certificateIssue) { _, newValue in
            if newValue != nil { certificateDismissed = false }
        }
    }

    @State private var certificateDismissed = false
}

struct LoginForm: View {
    let connection: ServerConnection
    let message: String?
    @State private var password = ""
    @State private var remember = false
    @State private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        Form {
            Section {
                LabeledContent("服务器", value: "\(connection.config.host):\(String(connection.config.port))")
                LabeledContent("用户", value: connection.config.account.userID)
                SecureField("密码", text: $password)
                    .textContentType(.password)
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(login)
                Toggle("记住密码", isOn: $remember)
            } header: {
                Text("登录")
            } footer: {
                Text("记住密码后密码保存在钥匙串中，登录票据彻底过期时自动重新登录；开启了二次验证的账号仍需输入验证码。")
            }
            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button(action: login) {
                    HStack {
                        Spacer()
                        if busy { ProgressView() } else { Text("登录") }
                        Spacer()
                    }
                }
                .disabled(password.isEmpty || busy)
            }
        }
        .onAppear {
            remember = connection.config.rememberPassword
            focused = true
        }
    }

    private func login() {
        guard !password.isEmpty, !busy else { return }
        busy = true
        Task {
            await connection.login(password: password, remember: remember)
            busy = false
            password = ""
        }
    }
}

struct TFASheet: View {
    let prompt: TFAPrompt
    let onAnswer: (TFAResponse?) -> Void
    @State private var method: TFAChallenge.Method = .totp
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("账号 \(prompt.challenge.username) 开启了二次验证。")
                    if prompt.challenge.supportedMethods.count > 1 {
                        Picker("验证方式", selection: $method) {
                            ForEach(prompt.challenge.supportedMethods, id: \.self) { method in
                                Text(title(method)).tag(method)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section {
                    switch method {
                    case .totp:
                        TextField("6 位验证码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focused)
                    case .recovery:
                        TextField("恢复码", text: $code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                        if let keys = prompt.challenge.recoveryKeysAvailable {
                            Text("剩余 \(keys.count) 个恢复码可用。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if prompt.challenge.webauthn || prompt.challenge.u2f || prompt.challenge.yubico {
                        Text("该账号还配置了 WebAuthn/U2F/Yubico，本 App 暂不支持这些方式。")
                    }
                }
            }
            .navigationTitle("二次验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onAnswer(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("验证") { submit() }
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                method = prompt.challenge.supportedMethods.first ?? .totp
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func title(_ method: TFAChallenge.Method) -> String {
        switch method {
        case .totp: return String(localized: "TOTP 验证码")
        case .recovery: return String(localized: "恢复码")
        }
    }

    private func submit() {
        switch method {
        case .totp: onAnswer(.totp(code))
        case .recovery: onAnswer(.recovery(code))
        }
    }
}

struct CertificateSheet: View {
    let issue: CertificateTrustFailure
    let onTrust: (CertificateFingerprint) -> Void
    let onCancel: () -> Void
    @State private var confirmMismatch = false

    var body: some View {
        NavigationStack {
            Form {
                switch issue {
                case .untrusted(let info):
                    Section {
                        Label("此服务器的证书不受系统信任（PVE 默认使用自签名证书）。", systemImage: "lock.trianglebadge.exclamationmark")
                        Text("请在 PVE 网页的“节点 › 系统 › 证书”中核对下面的 SHA-256 指纹。确认一致后，Chelate 以后只接受这个证书。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    details(info)
                    Section {
                        Button("指纹一致，信任此证书") { onTrust(info.fingerprint) }
                    }
                case .fingerprintMismatch(let expected, let presented):
                    Section {
                        Label("证书指纹已改变！", systemImage: "exclamationmark.octagon.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text("服务器出示的证书与你之前确认的不一致。如果你没有更换过 PVE 证书，这可能是中间人攻击，请不要继续。")
                    }
                    Section("之前确认的指纹") {
                        Text(expected.description)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    details(presented)
                    Section {
                        Toggle("我确认证书是我自己更换的", isOn: $confirmMismatch)
                        Button("信任新证书", role: .destructive) { onTrust(presented.fingerprint) }
                            .disabled(!confirmMismatch)
                    }
                }
            }
            .navigationTitle("证书验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private func details(_ info: CertificateInfo) -> some View {
        Section("服务器证书") {
            LabeledContent("主机", value: info.host)
            if let subject = info.subjectSummary {
                LabeledContent("主题", value: subject)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("SHA-256 指纹")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(info.fingerprint.description)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }
}
