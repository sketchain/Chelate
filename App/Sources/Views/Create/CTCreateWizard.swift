import PVEKit
import SwiftUI
import UniformTypeIdentifiers

/// 「新建容器」: 常规、模板、磁盘、CPU、内存、网络、DNS、确认 (`PVE.lxc.CreateWizard`).
struct CTCreateWizard: View {
    let connection: ServerConnection
    let presetNode: String?
    let onCreated: (TrackedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(WizardPreferences.advancedKey) private var advanced = false
    @State private var data: WizardData
    @State private var wizard = CTWizard()
    @State private var step: CTWizardStep = .general
    @State private var reached: CTWizardStep = .general
    @State private var selectedMount: UUID?
    @State private var importingKeys = false
    @State private var keyFileError: String?
    @State private var creating = false
    @State private var createError: String?
    @State private var cancelConfirm = false

    init(connection: ServerConnection, presetNode: String?, onCreated: @escaping (TrackedTask) -> Void) {
        self.connection = connection
        self.presetNode = presetNode
        self.onCreated = onCreated
        _data = State(initialValue: WizardData(connection: connection))
    }

    private var problems: [WizardProblem] {
        var list = wizard.problems(step)
        if step == .general && data.vmidFree == false {
            list.append(WizardProblem("vmid", String(localized: "该 CT ID 已被使用")))
        }
        if step == .general, let node = data.nodes.first(where: { $0.name == wizard.node }), !node.online {
            list.append(WizardProblem("nodename", String(localized: "节点 \(node.name) 似乎处于离线状态！")))
        }
        if step == .general, let keyFileError {
            list.append(WizardProblem("file", keyFileError))
        }
        return list
    }

    private var needs: [PermissionNeed] {
        var list = [PermissionNeed(.vmAllocate, on: wizard.vmid.map { PermissionNeed.vm($0) } ?? "/vms")]
        for storage in Set(wizard.mounts.map(\.storage)).sorted() where !storage.isEmpty {
            list.append(PermissionNeed(.datastoreAllocateSpace, on: PermissionNeed.storage(storage)))
        }
        if !wizard.pool.isEmpty { list.append(PermissionNeed(.poolAllocate, on: "/pool/\(wizard.pool)")) }
        return list
    }

    private var allStepsValid: Bool {
        CTWizardStep.allCases.allSatisfy { wizard.problems($0).isEmpty } && data.vmidFree != false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WizardStepBar(titles: CTWizardStep.allCases.map(\.title), current: step.rawValue, reached: reached.rawValue) { index in
                    if let target = CTWizardStep(rawValue: index), target.rawValue <= reached.rawValue { go(to: target) }
                }
                Divider()
                Form {
                    if let error = data.loadError {
                        Section { ErrorBanner(message: error) { Task { await data.loadCommon() } } }
                    }
                    stepContent
                    if step != .confirm {
                        WizardProblemsSection(problems: problems)
                    }
                }
                .accessibilityIdentifier("wizard-form")
                WizardBottomBar(
                    isFirst: step == .general,
                    isConfirm: step == .confirm,
                    canAdvance: step == .confirm ? connection.missing(needs).isEmpty && allStepsValid : problems.isEmpty,
                    creating: creating,
                    start: $wizard.start,
                    onBack: { if let previous = CTWizardStep(rawValue: step.rawValue - 1) { go(to: previous) } },
                    onNext: { if let next = CTWizardStep(rawValue: step.rawValue + 1) { go(to: next) } },
                    onCreate: { Task { await create() } }
                )
            }
            .navigationTitle("新建容器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancelConfirm = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("高级", isOn: $advanced)
                        .toggleStyle(.button)
                        .accessibilityIdentifier("wizard-advanced")
                }
            }
            .confirmationDialog("放弃新建容器？", isPresented: $cancelConfirm, titleVisibility: .visible) {
                Button("放弃", role: .destructive) { dismiss() }
            }
            .fileImporter(isPresented: $importingKeys, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                loadKeyFiles(result)
            }
            .task { await prepare() }
            .task(id: wizard.vmid) { await data.checkVMID(wizard.vmid) }
        }
        .interactiveDismissDisabled()
    }

    private func go(to target: CTWizardStep) {
        step = target
        if target.rawValue > reached.rawValue { reached = target }
    }

    private func prepare() async {
        await data.loadCommon()
        if wizard.vmid == nil { wizard.vmid = data.nextVMID }
        let node = presetNode ?? data.nodes.first(where: \.online)?.name ?? data.nodes.first?.name ?? ""
        await selectNode(node)
    }

    private func selectNode(_ node: String) async {
        wizard.node = node
        if let info = data.nodes.first(where: { $0.name == node }) {
            wizard.nodeArch = info.debianArch
            wizard.cgroupMode = info.cgroupMode
        }
        await data.loadNode(node, contents: ["vztmpl", "rootdir"])
        if !data.storages("vztmpl").contains(where: { $0.storage == wizard.templateStorage }) {
            wizard.templateStorage = data.storages("vztmpl").first?.storage ?? ""
            wizard.ostemplate = ""
        }
        if !data.bridges.contains(wizard.bridge) { wizard.bridge = data.bridges.first ?? "" }
        if let first = data.storages("rootdir").first {
            for index in wizard.mounts.indices where data.storage(wizard.mounts[index].storage, content: "rootdir") == nil {
                wizard.mounts[index].storage = first.storage
                wizard.mounts[index].storageType = first.type
            }
        }
        if selectedMount == nil { selectedMount = wizard.mounts.first?.id }
    }

    /// 「加载 SSH 密钥文件」: files up to 8192 bytes, appended line by line.
    private func loadKeyFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        keyFileError = nil
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= 8192, let text = String(data: data, encoding: .utf8) else {
                keyFileError = String(localized: "文件大小无效")
                continue
            }
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { continue }
            wizard.sshKeys = wizard.sshKeys.isEmpty ? key : wizard.sshKeys.trimmingCharacters(in: .newlines) + "\n" + key
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .general: generalStep
        case .template: templateStep
        case .disks: disksStep
        case .cpu: cpuStep
        case .memory: memoryStep
        case .network: networkStep
        case .dns: dnsStep
        case .confirm: confirmStep
        }
    }

    @ViewBuilder
    private var generalStep: some View {
        Section {
            Picker("节点", selection: Binding(get: { wizard.node }, set: { node in
                wizard.node = node
                Task { await selectNode(node) }
            })) {
                ForEach(data.nodes) { node in
                    Text(verbatim: node.online ? node.name : "\(node.name)（离线）").tag(node.name)
                }
            }
            OptionalIntField(title: "CT ID", value: $wizard.vmid)
            LabeledContent("主机名") {
                TextField("", text: $wizard.hostname)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle("无特权的容器", isOn: Binding(get: { wizard.unprivileged }, set: { wizard.setUnprivileged($0) }))
            Toggle("嵌套", isOn: $wizard.nesting)
                .disabled(!wizard.unprivileged)
            Toggle("添加到高可用", isOn: $wizard.haManaged)
            Picker("资源池", selection: $wizard.pool) {
                Text("无").tag("")
                ForEach(data.pools, id: \.self) { Text(verbatim: $0).tag($0) }
            }
        }
        Section {
            SecureField("密码", text: $wizard.password)
                .textContentType(.newPassword)
            SecureField("确认密码", text: $wizard.confirmPassword)
                .textContentType(.newPassword)
        } header: {
            Text("密码")
        } footer: {
            Text("至少 5 个字符。填写了 SSH 公钥时可以不设密码。")
        }
        Section {
            TextField("SSH 公钥", text: $wizard.sshKeys, axis: .vertical)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(3...8)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("加载 SSH 密钥文件", systemImage: "doc.badge.plus") { importingKeys = true }
        } header: {
            Text("SSH 公钥")
        }
        if advanced {
            Section("标签") {
                TagEditorRows(tags: $wizard.tags, suggestions: data.tags)
            }
        }
    }

    @ViewBuilder
    private var templateStep: some View {
        let all = data.volumes(node: wizard.node, storage: wizard.templateStorage, content: "vztmpl")
        let shown = all.filter { wizard.showsTemplate($0.volid) }
        Section {
            StoragePickerRow(title: "存储", storages: data.storages("vztmpl"), selection: Binding(get: { wizard.templateStorage }, set: { value in
                wizard.templateStorage = value
                wizard.ostemplate = ""
            }))
            Picker("模板", selection: $wizard.ostemplate) {
                Text("请选择").tag("")
                ForEach(shown) { item in
                    Text(verbatim: item.fileName).tag(item.volid)
                }
            }
            .task(id: "\(wizard.node)|\(wizard.templateStorage)") {
                await data.loadVolumes(node: wizard.node, storage: wizard.templateStorage, content: "vztmpl")
            }
            Toggle("显示所有架构", isOn: $wizard.showAllArchitectures)
        } footer: {
            if !all.isEmpty && shown.isEmpty {
                Text("没有适用于该架构的模板。请打开下方的“显示所有架构”。")
            }
        }
    }

    @ViewBuilder
    private var disksStep: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(wizard.sortedMounts) { mount in
                        let invalid = wizard.problems(.disks).contains { $0.field == "mount:\(mount.id.uuidString)" }
                        Button { selectedMount = mount.id } label: {
                            HStack(spacing: 4) {
                                if invalid { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                                Text(verbatim: mount.key)
                            }
                            .font(.subheadline.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedMount == mount.id ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Button {
                selectedMount = wizard.addMountPoint(storage: data.storages("rootdir").first)
            } label: {
                Label("添加挂载点", systemImage: "plus")
            }
            .accessibilityIdentifier("wizard-add-mount")
        } header: {
            Text("磁盘")
        } footer: {
            Text("根磁盘（rootfs）不能删除。")
        }
        if let mount = wizard.mounts.first(where: { $0.id == selectedMount }) ?? wizard.mounts.first {
            mountEditor(mount)
        }
    }

    private func mountBinding(_ id: UUID) -> Binding<CTMountDraft> {
        Binding(
            get: { wizard.mounts.first { $0.id == id } ?? CTMountDraft(isRoot: false) },
            set: { value in
                if let index = wizard.mounts.firstIndex(where: { $0.id == id }) { wizard.mounts[index] = value }
            }
        )
    }

    @ViewBuilder
    private func mountEditor(_ mount: CTMountDraft) -> some View {
        let binding = mountBinding(mount.id)
        Section {
            if !mount.isRoot {
                IntField(title: "挂载点 ID", value: binding.mpid)
            }
            StoragePickerRow(title: "存储", storages: data.storages("rootdir"), selection: Binding(get: { mount.storage }, set: { name in
                binding.wrappedValue.storage = name
                binding.wrappedValue.storageType = data.storage(name, content: "rootdir")?.type ?? ""
                if !binding.wrappedValue.quotaAvailable(unprivileged: wizard.unprivileged) { binding.wrappedValue.quota = false }
            }))
            OptionalDoubleField(title: "磁盘大小 (GiB)", value: Binding(get: { mount.size }, set: { binding.wrappedValue.size = $0 ?? 0 }))
            if !mount.isRoot {
                LabeledContent("路径") {
                    TextField("/some/path", text: binding.path)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Toggle("备份", isOn: binding.backup)
            }
        } header: {
            HStack {
                Text(verbatim: mount.key)
                Spacer()
                if !mount.isRoot {
                    Button("删除", role: .destructive) {
                        wizard.mounts.removeAll { $0.id == mount.id }
                        selectedMount = wizard.mounts.first?.id
                    }
                    .textCase(nil)
                }
            }
        } footer: {
            if !mount.isRoot { Text("“备份”：在备份作业中包括卷。") }
        }
        if advanced {
            Section("高级") {
                Toggle("启用配额", isOn: binding.quota)
                    .disabled(!mount.quotaAvailable(unprivileged: wizard.unprivileged))
                if !mount.isRoot {
                    Toggle("只读", isOn: binding.readOnly)
                }
                Picker("ACLs", selection: Binding(get: { mount.acl.map { $0 ? "1" : "0" } ?? "__default__" }, set: { value in
                    binding.wrappedValue.acl = value == "__default__" ? nil : value == "1"
                })) {
                    Text("默认").tag("__default__")
                    Text("已启用").tag("1")
                    Text("已禁用").tag("0")
                }
                Toggle("跳过复制", isOn: binding.skipReplication)
                if !mount.isRoot {
                    Toggle("保留属性", isOn: binding.keepAttributes)
                }
            }
            Section("挂载选项") {
                ForEach(mount.availableMountOptions, id: \.self) { option in
                    Toggle(option, isOn: Binding(get: { mount.mountOptions.contains(option) }, set: { on in
                        if on { binding.wrappedValue.mountOptions.append(option) } else { binding.wrappedValue.mountOptions.removeAll { $0 == option } }
                    }))
                }
            }
            Section {
                Toggle("直通", isOn: binding.idmapPassthrough)
                if !mount.idmapPassthrough {
                    ForEach(mount.idmap) { row in
                        idmapRow(mount: binding, rowID: row.id)
                    }
                    HStack {
                        Button("添加") { binding.wrappedValue.idmap.append(IDMapRow()) }
                        Spacer()
                        Button("清除", role: .destructive) { binding.wrappedValue.idmap.removeAll() }
                            .disabled(mount.idmap.isEmpty)
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("ID 映射")
            } footer: {
                Text("只提交四列都填写完整的行。")
            }
        }
    }

    @ViewBuilder
    private func idmapRow(mount: Binding<CTMountDraft>, rowID: UUID) -> some View {
        let row = Binding<IDMapRow>(
            get: { mount.wrappedValue.idmap.first { $0.id == rowID } ?? IDMapRow() },
            set: { value in
                if let index = mount.wrappedValue.idmap.firstIndex(where: { $0.id == rowID }) { mount.wrappedValue.idmap[index] = value }
            }
        )
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("ID 类型", selection: row.type) {
                    Text("UID").tag("u")
                    Text("GID").tag("g")
                }
                .pickerStyle(.segmented)
                Button(role: .destructive) {
                    mount.wrappedValue.idmap.removeAll { $0.id == rowID }
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
            }
            OptionalIntField(title: "容器 ID", value: row.containerID)
            OptionalIntField(title: "主机 ID", value: row.hostID)
            OptionalIntField(title: "范围大小", value: row.size)
        }
    }

    @ViewBuilder
    private var cpuStep: some View {
        Section {
            OptionalIntField(title: "核心", value: $wizard.cores, prompt: String(localized: "无限制"))
        }
        if advanced {
            Section("高级") {
                OptionalDoubleField(title: "CPU 限制", value: $wizard.cpulimit, prompt: String(localized: "无限制"))
                OptionalIntField(title: "CPU 权重", value: $wizard.cpuunits, prompt: "\(wizard.defaultCPUUnits)")
            }
        }
    }

    @ViewBuilder
    private var memoryStep: some View {
        Section {
            IntField(title: "内存 (MiB)", value: $wizard.memory)
            IntField(title: "Swap (MiB)", value: $wizard.swap)
        }
    }

    @ViewBuilder
    private var networkStep: some View {
        Section {
            LabeledContent("名称") {
                TextField("(e.g., eth0)", text: $wizard.interfaceName)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("MAC 地址") {
                TextField("auto", text: $wizard.hwaddr)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Picker("桥接", selection: $wizard.bridge) {
                if wizard.bridge.isEmpty { Text("请选择").tag("") }
                ForEach(data.bridges, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            OptionalIntField(title: "VLAN 标签", value: $wizard.vlanTag, prompt: String(localized: "无 VLAN"))
            Toggle("防火墙", isOn: $wizard.firewall)
        }
        Section("IPv4") {
            Picker("IPv4", selection: $wizard.ipv4Mode) {
                Text("静态").tag(IPv4Mode.static)
                Text("DHCP").tag(IPv4Mode.dhcp)
            }
            .pickerStyle(.segmented)
            Group {
                LabeledContent("IPv4/CIDR") {
                    TextField(String(localized: "无"), text: $wizard.ipv4)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
                LabeledContent("网关 (IPv4)") {
                    TextField("", text: $wizard.gateway4)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                }
            }
            .disabled(wizard.ipv4Mode != .static)
        }
        Section("IPv6") {
            Picker("IPv6", selection: $wizard.ipv6Mode) {
                Text("静态").tag(IPv6Mode.static)
                Text("DHCP").tag(IPv6Mode.dhcp)
                Text("SLAAC").tag(IPv6Mode.auto)
            }
            .pickerStyle(.segmented)
            Group {
                LabeledContent("IPv6/CIDR") {
                    TextField(String(localized: "无"), text: $wizard.ipv6)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("网关 (IPv6)") {
                    TextField("", text: $wizard.gateway6)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .disabled(wizard.ipv6Mode != .static)
        }
        if advanced {
            Section("高级") {
                Toggle("断开", isOn: $wizard.linkDown)
                OptionalIntField(title: "MTU", value: $wizard.mtu, prompt: String(localized: "与网桥相同"))
                OptionalDoubleField(title: "速率限制 (MB/s)", value: $wizard.rate, prompt: "unlimited")
                Toggle("主机管理", isOn: $wizard.hostManaged)
            }
        }
    }

    @ViewBuilder
    private var dnsStep: some View {
        Section {
            LabeledContent("DNS 域") {
                TextField(String(localized: "使用主机设置"), text: $wizard.searchDomain)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            LabeledContent("DNS 服务器") {
                TextField(String(localized: "使用主机设置"), text: $wizard.nameservers)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        } footer: {
            Text("多个 DNS 服务器用空格、逗号或分号分隔。")
        }
    }

    @ViewBuilder
    private var confirmStep: some View {
        let missing = connection.missing(needs)
        ForEach(CTWizardStep.allCases.filter { $0 != .confirm }) { group in
            WizardConfirmGroup(title: group.title, settings: wizard.settings(for: group)) { go(to: group) }
        }
        if !missing.isEmpty {
            Section { MissingPermissionLabel(action: "创建容器", missing: missing) }
        }
        if let createError {
            Section { ErrorBanner(message: createError) }
        }
    }

    private func create() async {
        creating = true
        defer { creating = false }
        let request = wizard
        let result = await connection.run(.vmAllocate, on: PermissionNeed.vm(request.vmid ?? 0)) { client in
            try await client.createContainer(request)
        }
        switch result {
        case .success(let upid):
            onCreated(TrackedTask(upid: upid, title: String(localized: "新建容器 \(String(request.vmid ?? 0))")))
        case .failure(let failure):
            createError = failure.message
        }
    }
}
