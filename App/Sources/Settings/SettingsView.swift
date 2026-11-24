import PVEKit
import SwiftUI

/// Settings in the detail column, with its own navigation stack.
struct SettingsStack: View {
    var body: some View {
        NavigationStack {
            SettingsView()
                .navigationDestination(for: SettingsRoute.self) { route in
                    switch route {
                    case .server(let id): ServerSettingsView(serverID: id)
                    case .about: AboutView()
                    case .widgetGallery: WidgetGalleryView()
                    }
                }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(AppLock.self) private var lock

    @State private var adding: ServerConfig?
    @State private var syncResult: String?
    @State private var lockError: String?

    var body: some View {
        @Bindable var settings = settings
        List {
            serversSection
            Section("通用") {
                Picker("自动刷新", selection: $settings.autoRefresh) {
                    ForEach(AppSettings.AutoRefresh.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("settings-auto-refresh")
                Picker("图表默认时间范围", selection: $settings.chartTimeframe) {
                    ForEach(RRDTimeframe.allCases) { frame in
                        Text(frame.title).tag(frame)
                    }
                }
            }
            Section("外观") {
                Picker("主题", selection: $settings.theme) {
                    ForEach(AppSettings.Theme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                AccentPicker(selection: $settings.accent)
            }
            securitySection
            dataSection
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $adding) { config in
            ServerEditView(original: config, isNew: true, selectsNewServer: false)
        }
        .alert("小组件数据", isPresented: Binding(get: { syncResult != nil }, set: { if !$0 { syncResult = nil } })) {
            Button("好") {}
        } message: {
            Text(syncResult ?? "")
        }
    }

    private var serversSection: some View {
        Section("服务器") {
            ForEach(model.servers) { server in
                NavigationLink(value: SettingsRoute.server(server.id)) {
                    LabeledContent {
                        Text(server.pinnedFingerprint == nil ? "系统证书" : "已信任证书")
                    } label: {
                        Text(verbatim: server.displayName)
                            .lineLimit(1)
                    }
                }
                .accessibilityIdentifier("settings-server-\(server.displayName)")
            }
            Button {
                adding = ServerConfig()
            } label: {
                Label("添加服务器", systemImage: "plus.circle")
            }
        }
    }

    private var securitySection: some View {
        Section {
            Toggle(isOn: Binding(get: { settings.faceIDLock }, set: setFaceIDLock)) {
                Text("\(AppLock.biometryName) 解锁")
            }
            Toggle("危险操作二次确认", isOn: Binding(get: { settings.confirmDangerousActions }, set: { settings.confirmDangerousActions = $0 }))
        } header: {
            Text("安全")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let lockError {
                    Text(lockError)
                }
                Text("开启解锁后，冷启动和离开超过 5 分钟后回到 App 时需要验证身份，多任务界面不显示内容。二次确认作用于关机、重启、强制停止和暂停；快照回滚和删除始终需要确认。")
            }
        }
    }

    private var dataSection: some View {
        Section {
            if WidgetMirror.isWidgetVariant {
                Button {
                    syncResult = model.syncWidgets()
                        ? String(localized: "已把服务器配置和凭据同步到小组件，并刷新了所有小组件。")
                        : String(localized: "同步失败：App Group 不可用，请检查签名。")
                } label: {
                    Label("重新同步小组件数据", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!WidgetMirror.isAvailable || DemoMode.isEnabled)
                if !WidgetMirror.isAvailable && !DemoMode.isEnabled {
                    Label("App Group 不可用，请检查签名", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            ShareLink(item: LogExport(), preview: SharePreview("Chelate 日志")) {
                Label("导出日志", systemImage: "square.and.arrow.up")
            }
            if DemoMode.isEnabled {
                NavigationLink(value: SettingsRoute.widgetGallery) {
                    Label("小组件展示", systemImage: "square.grid.2x2")
                }
                .accessibilityIdentifier("settings-widget-gallery")
            }
            NavigationLink(value: SettingsRoute.about) {
                LabeledContent {
                    Text(verbatim: "\(BuildInfo.version) (\(BuildInfo.build))")
                        .monospacedDigit()
                } label: {
                    Label("关于", systemImage: "info.circle")
                }
            }
        } header: {
            Text("数据")
        } footer: {
            Text("日志包含网络请求结果、错误和认证事件，导出前会去掉 Token、ticket、CSRF token 和密码。")
        }
    }

    private func setFaceIDLock(_ enabled: Bool) {
        lockError = nil
        guard enabled else {
            settings.faceIDLock = false
            lock.disable()
            return
        }
        Task {
            // Only enable after a successful check, so nobody locks themselves out.
            if await AppLock.authenticate(reason: String(localized: "开启 Chelate 解锁")) {
                settings.faceIDLock = true
            } else {
                lockError = String(localized: "未能验证身份，解锁未开启。")
            }
        }
    }
}

/// Five colour dots; the selected one has a ring.
struct AccentPicker: View {
    @Binding var selection: AccentPreset

    var body: some View {
        LabeledContent("强调色") {
            HStack(spacing: 10) {
                ForEach(AccentPreset.allCases) { preset in
                    Button {
                        selection = preset
                    } label: {
                        Circle()
                            .fill(preset.color)
                            .frame(width: 24, height: 24)
                            .overlay {
                                if preset == selection {
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.85), lineWidth: 2)
                                        .padding(-4)
                                }
                            }
                            .padding(4)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(preset.title))
                    .accessibilityAddTraits(preset == selection ? .isSelected : [])
                }
            }
        }
    }
}
