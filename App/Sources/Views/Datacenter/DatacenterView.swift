import PVEKit
import SwiftUI

/// 「数据中心」: cluster quorum and HA resources (read only), replication jobs (read only) and
/// the datacenter firewall.
struct DatacenterView: View {
    let connection: ServerConnection

    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings
    @State private var cluster: ClusterStatus?
    @State private var haStatus: [HAStatusEntry] = []
    @State private var haResources: [HAResource] = []
    @State private var replication: [ReplicationJob] = []
    @State private var error: ActionError?
    @State private var loaded = false

    var body: some View {
        List {
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看数据中心（需要 / 上的 Sys.Audit）")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            Section {
                LabeledContent("集群") {
                    Text(verbatim: cluster?.clusterName ?? String(localized: "单节点（未组建集群）"))
                }
                LabeledContent("仲裁") {
                    HStack(spacing: 6) {
                        StatusDot(status: quorate ? "running" : "stopped")
                        Text(quorate ? "正常" : "无仲裁")
                    }
                }
                if let cluster, !cluster.nodes.isEmpty {
                    LabeledContent("节点", value: "\(cluster.onlineNodes.count) / \(cluster.nodes.count) 在线")
                }
                ForEach(haStatus.filter { $0.type == "master" || $0.type == "lrm" }) { entry in
                    InfoRow(title: entry.type == "master" ? "管理器" : "本地资源管理器", value: entry.status, raw: entry.status)
                }
            } header: {
                Text("高可用")
            }
            Section {
                if loaded && haResources.isEmpty {
                    Text("没有高可用资源").foregroundStyle(.secondary)
                }
                ForEach(haResources) { resource in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(verbatim: resource.sid).font(.body)
                            Spacer()
                            Text(verbatim: resource.currentState ?? resource.requestedState ?? "–")
                                .foregroundStyle(.secondary)
                        }
                        Text(verbatim: [
                            resource.node.map { String(localized: "节点 \($0)") },
                            resource.requestedState.map { String(localized: "请求 \($0)") },
                            resource.comment,
                        ].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("高可用资源")
            } footer: {
                Text("只读。")
            }
            Section {
                if loaded && replication.isEmpty {
                    Text("没有复制任务").foregroundStyle(.secondary)
                }
                ForEach(replication) { job in
                    ReplicationRow(job: job)
                }
            } header: {
                Text("复制")
            } footer: {
                Text("只读。")
            }
            Section {
                NavigationLink(value: Route.firewall(.datacenter)) {
                    Label("防火墙", systemImage: "flame")
                }
                .accessibilityIdentifier("datacenter-firewall")
            }
        }
        .navigationTitle("数据中心")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: RefreshTrigger(phase: scenePhase, interval: settings.autoRefresh)) {
            guard scenePhase == .active else { return }
            await connection.loadPermissions(path: "/")
            await autoRefresh(settings.autoRefresh) { await load() }
        }
    }

    private var quorate: Bool {
        cluster?.quorate ?? haStatus.first(where: { $0.type == "quorum" })?.quorate ?? true
    }

    private func load() async {
        let resources = connection.resources
        let sourceNode: @Sendable (Int) -> String? = { vmid in
            resources.first { $0.vmid == vmid }?.node
        }
        let result = await connection.run(.sysAudit, on: "/") { client in
            async let cluster = client.clusterStatus()
            async let status = client.haStatus()
            let haStatus = (try? await status) ?? []
            let haResources = (try? await client.haResources(status: haStatus)) ?? []
            let jobs = (try? await client.replicationJobs(sourceNode: sourceNode)) ?? []
            return (try await cluster, haStatus, haResources, jobs)
        }
        loaded = true
        switch result {
        case .success(let value):
            cluster = value.0
            haStatus = value.1
            haResources = value.2
            replication = value.3
            error = nil
        case .failure(let failure):
            if case .failed(let text) = failure, text == ErrorText.message(for: PVEError.cancelled) { return }
            error = failure
        }
    }
}

struct ReplicationRow: View {
    let job: ReplicationJob

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: job.id).font(.body)
                if job.disabled {
                    Text("已禁用").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                Spacer()
                if job.isHealthy {
                    Label("正常", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                } else {
                    Label("错误", systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.caption)
                }
            }
            Group {
                Text(verbatim: "\(job.guest.map(String.init) ?? "–") → \(job.target ?? "–")")
                Text("上次同步：\(Format.shortDate(job.lastSync)) · 耗时 \(job.duration.map { String(format: "%.1f s", $0) } ?? "–")")
                Text("下次同步：\(Format.shortDate(job.nextSync))")
                if let failCount = job.failCount, failCount > 0 {
                    Text("失败次数：\(failCount)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            if let error = job.error {
                Text(verbatim: error).font(.caption).foregroundStyle(.red)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Firewall of one level: the 「启用防火墙」 switch and the rules, read only. Enabling the
/// datacenter firewall always asks for confirmation (lock-out warning).
struct FirewallView: View {
    let connection: ServerConnection
    let scope: FirewallScope

    @State private var options: FirewallOptions?
    @State private var rules: [FirewallRule] = []
    @State private var error: ActionError?
    @State private var loaded = false
    @State private var confirmEnable = false
    @State private var saving = false
    @State private var message: String?

    private var title: String {
        switch scope {
        case .datacenter: return String(localized: "数据中心防火墙")
        case .node(let node): return String(localized: "\(node) 防火墙")
        case .guest(let guest): return String(localized: "\(String(guest.vmid)) 防火墙")
        }
    }

    var body: some View {
        let modifyMissing = connection.missing([PermissionNeed(scope.modifyPrivilege, on: scope.aclPath)])
        List {
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看防火墙（需要 \(scope.aclPath) 上的 \(scope.readPrivilege.rawValue)）")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            Section {
                Toggle("启用防火墙", isOn: Binding(
                    get: { options?.enabled ?? false },
                    set: { newValue in
                        if newValue, case .datacenter = scope {
                            confirmEnable = true
                        } else {
                            Task { await setEnabled(newValue) }
                        }
                    }
                ))
                .disabled(options == nil || saving || !modifyMissing.isEmpty)
                .accessibilityIdentifier("firewall-enable")
            } footer: {
                if !modifyMissing.isEmpty {
                    MissingPermissionLabel(action: "修改防火墙", missing: modifyMissing)
                } else if case .datacenter = scope {
                    Text("数据中心防火墙是总开关：关闭时节点和客户机的防火墙规则都不生效。")
                }
            }
            Section {
                if loaded && rules.isEmpty && error == nil {
                    Text("没有规则").foregroundStyle(.secondary)
                }
                ForEach(rules) { rule in
                    FirewallRuleRow(rule: rule)
                }
            } header: {
                Text("规则")
            } footer: {
                Text("只读。规则请在 PVE 网页中编辑。")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            await connection.loadPermissions(path: scope.aclPath)
            await load()
        }
        .confirmationDialog("启用数据中心防火墙", isPresented: $confirmEnable, titleVisibility: .visible) {
            Button("仍然启用", role: .destructive) { Task { await setEnabled(true) } }
        } message: {
            Text("没有放行规则时，启用后可能把自己锁在外面（包括 PVE 网页和本 App）。请先确认已放行 8006 端口（WebUI / API）和 SSH。")
        }
        .alert("操作未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") {}
        } message: {
            Text(message ?? "")
        }
    }

    private func load() async {
        let result = await connection.run(scope.readPrivilege, on: scope.aclPath) { client in
            async let options = client.firewallOptions(scope)
            async let rules = client.firewallRules(scope)
            return try await (options, rules)
        }
        loaded = true
        switch result {
        case .success(let value):
            options = value.0
            rules = value.1
            error = nil
        case .failure(let failure):
            if case .failed(let text) = failure, text == ErrorText.message(for: PVEError.cancelled) { return }
            error = failure
        }
    }

    private func setEnabled(_ enabled: Bool) async {
        saving = true
        defer { saving = false }
        let result = await connection.run(scope.modifyPrivilege, on: scope.aclPath) { client in
            try await client.setFirewall(scope, enabled: enabled)
        }
        switch result {
        case .success:
            await load()
        case .failure(let failure):
            message = failure.message
        }
    }
}

/// Direction, action, source, destination, protocol, port, comment and enabled state.
struct FirewallRuleRow: View {
    let rule: FirewallRule

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(verbatim: direction).font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                Text(verbatim: rule.action)
                    .font(.body.weight(.medium))
                    .foregroundStyle(actionColor)
                Spacer()
                Text(rule.enabled ? "已启用" : "未启用")
                    .font(.caption)
                    .foregroundStyle(rule.enabled ? .green : .secondary)
            }
            Text(verbatim: "\(rule.source ?? String(localized: "任意")) → \(rule.dest ?? String(localized: "任意"))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(verbatim: [rule.protocolText, rule.portText.map { String(localized: "端口 \($0)") }].compactMap { $0 }.joined(separator: " · ").ifEmpty(String(localized: "所有协议")))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let comment = rule.comment {
                Text(verbatim: comment).font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(rule.enabled ? 1 : 0.6)
        .accessibilityElement(children: .combine)
    }

    private var direction: String {
        switch rule.type {
        case "in": return String(localized: "入站")
        case "out": return String(localized: "出站")
        case "forward": return String(localized: "转发")
        case "group": return String(localized: "安全组")
        default: return rule.type
        }
    }

    private var actionColor: Color {
        switch rule.action {
        case "ACCEPT": return .green
        case "DROP", "REJECT": return .red
        default: return .primary
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
