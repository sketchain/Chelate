import PVEKit
import SwiftUI

/// 「新建虚拟机」: 常规、操作系统、系统、磁盘、CPU、内存、网络、确认 (`PVE.qemu.CreateWizard`).
struct VMCreateWizard: View {
    let connection: ServerConnection
    let presetNode: String?
    let onCreated: (TrackedTask) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(WizardPreferences.advancedKey) private var advanced = false
    @State private var data: WizardData
    @State private var wizard = VMWizard()
    @State private var step: VMWizardStep = .general
    @State private var reached: VMWizardStep = .general
    @State private var osShown = false
    @State private var selectedDisk: UUID?
    @State private var diskTab = 0
    @State private var onlySupportedFlags = true
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
            list.append(WizardProblem("vmid", String(localized: "该 VM ID 已被使用")))
        }
        if step == .general, let node = data.nodes.first(where: { $0.name == wizard.node }), !node.online {
            list.append(WizardProblem("nodename", String(localized: "节点 \(node.name) 似乎处于离线状态！")))
        }
        return list
    }

    private var needs: [PermissionNeed] {
        var list = [PermissionNeed(.vmAllocate, on: wizard.vmid.map { PermissionNeed.vm($0) } ?? "/vms")]
        var storages = Set(wizard.disks.map(\.target.storage))
        if wizard.usesOVMF && wizard.addEFIDisk { storages.insert(wizard.efi.storage) }
        if wizard.addTPM { storages.insert(wizard.tpm.storage) }
        for storage in storages.sorted() where !storage.isEmpty {
            list.append(PermissionNeed(.datastoreAllocateSpace, on: PermissionNeed.storage(storage)))
        }
        if !wizard.pool.isEmpty { list.append(PermissionNeed(.poolAllocate, on: "/pool/\(wizard.pool)")) }
        return list
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WizardStepBar(titles: VMWizardStep.allCases.map(\.title), current: step.rawValue, reached: reached.rawValue) { index in
                    if let target = VMWizardStep(rawValue: index), target.rawValue <= reached.rawValue { go(to: target) }
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
                    onBack: { if let previous = VMWizardStep(rawValue: step.rawValue - 1) { go(to: previous) } },
                    onNext: { if let next = VMWizardStep(rawValue: step.rawValue + 1) { go(to: next) } },
                    onCreate: { Task { await create() } }
                )
            }
            .navigationTitle("新建虚拟机")
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
            .confirmationDialog("放弃新建虚拟机？", isPresented: $cancelConfirm, titleVisibility: .visible) {
                Button("放弃", role: .destructive) { dismiss() }
            }
            .task { await prepare() }
            .task(id: wizard.vmid) { await data.checkVMID(wizard.vmid) }
            .task(id: wizard.effectiveArch) { await data.loadCPU(arch: wizard.effectiveArch) }
        }
        .interactiveDismissDisabled()
    }

    private var allStepsValid: Bool {
        VMWizardStep.allCases.allSatisfy { wizard.problems($0).isEmpty } && data.vmidFree != false
    }

    private func go(to target: VMWizardStep) {
        step = target
        if target.rawValue > reached.rawValue { reached = target }
        switch target {
        case .os where !osShown:
            osShown = true
            wizard.applyOSType(wizard.ostype)
        case .system:
            wizard.applySystemDefaultsIfNeeded()
            if wizard.efi.storage.isEmpty, let first = data.storages("images").first { wizard.efi.select(first) }
            if wizard.tpm.storage.isEmpty, let first = data.storages("images").first { wizard.tpm.select(first) }
        case .memory:
            wizard.applyMemoryDefaultsIfNeeded()
        default:
            break
        }
    }

    private func prepare() async {
        wizard.isRootUser = connection.client.auth.authID == "root@pam" && !connection.usesAPIToken
        await data.loadCommon()
        if wizard.vmid == nil { wizard.vmid = data.nextVMID }
        let node = presetNode ?? data.nodes.first(where: \.online)?.name ?? data.nodes.first?.name ?? ""
        await selectNode(node)
    }

    private func selectNode(_ node: String) async {
        wizard.node = node
        if let info = data.nodes.first(where: { $0.name == node }) {
            wizard.hostArch = info.arch
            wizard.cgroupMode = info.cgroupMode
            wizard.normalizeForArch()
        }
        await data.loadNode(node, contents: ["iso", "images", "import"])
        if !data.storages("iso").contains(where: { $0.storage == wizard.isoStorage }) {
            wizard.isoStorage = data.storages("iso").first?.storage ?? ""
            wizard.isoVolume = ""
        }
        if !data.storages("iso").contains(where: { $0.storage == wizard.driversStorage }) {
            wizard.driversStorage = data.storages("iso").first?.storage ?? ""
            wizard.driversVolume = ""
        }
        if !data.bridges.contains(wizard.bridge) { wizard.bridge = data.bridges.first ?? "" }
        let firstImages = data.storages("images").first
        for index in wizard.disks.indices where data.storage(wizard.disks[index].target.storage, content: "images") == nil {
            if let firstImages { wizard.disks[index].target.select(firstImages) }
        }
        // The first disk appears as soon as the node is known.
        if wizard.disks.isEmpty, !node.isEmpty {
            selectedDisk = wizard.addDisk(storage: firstImages)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .general: generalStep
        case .os: osStep
        case .system: systemStep
        case .disks: disksStep
        case .cpu: cpuStep
        case .memory: memoryStep
        case .network: networkStep
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
            OptionalIntField(title: "VM ID", value: $wizard.vmid)
            LabeledContent("名称") {
                TextField("", text: $wizard.name)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Toggle("添加到高可用", isOn: $wizard.haManaged)
            Picker("资源池", selection: $wizard.pool) {
                Text("无").tag("")
                ForEach(data.pools, id: \.self) { Text(verbatim: $0).tag($0) }
            }
        }
        if advanced {
            Section("高级") {
                Toggle("开机自启动", isOn: $wizard.onboot)
                LabeledContent("启动/关机顺序") {
                    TextField("any", text: $wizard.order).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                }
                LabeledContent("启动延时") {
                    TextField("default", text: $wizard.up).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                }
                LabeledContent("关机超时") {
                    TextField("default", text: $wizard.down).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                }
                Picker("vCPU 架构", selection: Binding(get: { wizard.arch?.rawValue ?? "__default__" }, set: { value in
                    wizard.arch = GuestArch(rawValue: value)
                    wizard.normalizeForArch()
                })) {
                    Text("默认（宿主架构）").tag("__default__")
                    Text(verbatim: "x86 (64-bit)").tag(GuestArch.x86_64.rawValue)
                    Text(verbatim: "ARM (64-bit)").tag(GuestArch.aarch64.rawValue)
                }
            }
            Section("标签") {
                TagEditorRows(tags: $wizard.tags, suggestions: data.tags)
            }
        }
    }

    @ViewBuilder
    private var osStep: some View {
        Section {
            Picker("介质", selection: $wizard.media) {
                Text("使用 CD/DVD 光盘镜像文件（ISO）").tag(CDMedia.iso)
                Text("使用物理 CD/DVD 驱动器").tag(CDMedia.cdrom)
                Text("不使用任何介质").tag(CDMedia.none)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if wizard.media == .iso {
                StoragePickerRow(title: "存储", storages: data.storages("iso"), selection: $wizard.isoStorage)
                VolumePickerRow(title: "ISO 镜像", data: data, node: wizard.node, storage: wizard.isoStorage, content: "iso", selection: $wizard.isoVolume)
            }
        } header: {
            Text("安装介质（\(wizard.installDriveKey)）")
        }
        Section("客户机操作系统") {
            Picker("类型", selection: Binding(get: { wizard.osBase }, set: { base in
                if let first = QemuOSType.types(for: base, arch: wizard.effectiveArch).first { wizard.applyOSType(first.value) }
            })) {
                ForEach(QemuOSBase.available(for: wizard.effectiveArch)) { base in
                    Text(verbatim: base.title).tag(base)
                }
            }
            Picker("版本", selection: Binding(get: { wizard.ostype }, set: { wizard.applyOSType($0) })) {
                ForEach(QemuOSType.types(for: wizard.osBase, arch: wizard.effectiveArch)) { type in
                    Text(verbatim: "\(wizard.osBase.title) \(type.label)").tag(type.value)
                }
            }
            if wizard.osBase == .windows {
                Toggle("为 VirtIO 驱动程序添加额外驱动器", isOn: Binding(get: { wizard.virtioDriversCD }, set: { wizard.setVirtIODriversCD($0) }))
                if wizard.virtioDriversCD {
                    StoragePickerRow(title: "存储", storages: data.storages("iso"), selection: $wizard.driversStorage)
                    VolumePickerRow(title: "ISO 镜像", data: data, node: wizard.node, storage: wizard.driversStorage, content: "iso", selection: $wizard.driversVolume)
                }
            }
        }
    }

    @ViewBuilder
    private var systemStep: some View {
        let arch = wizard.effectiveArch
        Section {
            OptionPicker(title: "显卡", options: QemuWizardOptions.vga, selection: $wizard.vga)
            OptionPicker(title: "机型", options: QemuWizardOptions.machines(for: arch), selection: $wizard.machine)
            OptionPicker(title: "SCSI 控制器", options: QemuWizardOptions.scsiControllers(for: arch), selection: Binding(get: { wizard.scsihw }, set: { wizard.setSCSIController($0) }))
            Toggle("Qemu 代理", isOn: $wizard.agent)
        }
        Section("固件") {
            OptionPicker(title: "BIOS", options: QemuWizardOptions.bioses(for: arch), selection: $wizard.bios)
            if wizard.usesOVMF {
                Toggle("添加 EFI 磁盘", isOn: $wizard.addEFIDisk)
                if wizard.addEFIDisk {
                    DiskTargetRows(storageTitle: "EFI 存储", data: data, node: wizard.node, target: $wizard.efi)
                    Toggle("预注册密钥", isOn: $wizard.preEnrolledKeys)
                }
            }
        }
        Section {
            Toggle("添加 TPM", isOn: $wizard.addTPM)
            if wizard.addTPM {
                DiskTargetRows(storageTitle: "TPM 存储", data: data, node: wizard.node, target: $wizard.tpm)
                Picker("版本", selection: $wizard.tpmVersion) {
                    ForEach(QemuWizardOptions.tpmVersions(for: arch), id: \.self) { Text(verbatim: $0).tag($0) }
                }
            }
        } footer: {
            if wizard.usesOVMF && wizard.addEFIDisk && wizard.preEnrolledKeys {
                Text("预注册密钥：使用带标准发行版和 Microsoft 安全启动密钥的 EFIvars 映像。")
            }
        }
    }

    // MARK: Disks

    @ViewBuilder
    private var disksStep: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(wizard.sortedDisks) { disk in
                        let invalid = wizard.problems(.disks).contains { $0.field == "disk:\(disk.id.uuidString)" }
                        Button {
                            selectedDisk = disk.id
                        } label: {
                            HStack(spacing: 4) {
                                if invalid { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                                Text(verbatim: disk.key)
                            }
                            .font(.subheadline.monospaced())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(selectedDisk == disk.id ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if wizard.disks.isEmpty {
                Text("没有磁盘").foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button {
                    selectedDisk = wizard.addDisk(storage: data.storages("images").first)
                } label: {
                    Label("添加", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("wizard-add-disk")
                Button {
                    selectedDisk = wizard.addDisk(isImport: true, storage: data.storages("images").first)
                } label: {
                    Label("导入", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .disabled(data.storages("import").isEmpty)
            }
            .buttonStyle(.bordered)
        } header: {
            Text("磁盘")
        } footer: {
            Text("每块磁盘的总线/设备不能重复。可以删除所有磁盘。")
        }
        if let index = wizard.disks.firstIndex(where: { $0.id == selectedDisk }) ?? (wizard.disks.isEmpty ? nil : 0) {
            diskEditor(index)
        }
    }

    /// Binding by id, so a removed disk never indexes out of range.
    private func diskBinding(_ id: UUID) -> Binding<VMDiskDraft> {
        Binding(
            get: { wizard.disks.first { $0.id == id } ?? VMDiskDraft(bus: .scsi, device: 0) },
            set: { value in
                if let index = wizard.disks.firstIndex(where: { $0.id == id }) { wizard.disks[index] = value }
            }
        )
    }

    @ViewBuilder
    private func diskEditor(_ index: Int) -> some View {
        let disk = wizard.disks[index]
        let binding = diskBinding(disk.id)
        Section {
            Picker("", selection: $diskTab) {
                Text("磁盘").tag(0)
                Text("带宽").tag(1)
            }
            .pickerStyle(.segmented)
        } header: {
            HStack {
                Text(verbatim: disk.isImport ? String(localized: "导入磁盘 \(disk.key)") : disk.key)
                Spacer()
                Button("删除", role: .destructive) {
                    wizard.disks.removeAll { $0.id == disk.id }
                    selectedDisk = wizard.sortedDisks.first?.id
                }
                .textCase(nil)
                .accessibilityIdentifier("wizard-remove-disk")
            }
        }
        if diskTab == 0 {
            Section {
                Picker("总线", selection: Binding(get: { binding.wrappedValue.bus }, set: { wizard.setBus(of: disk.id, to: $0) })) {
                    ForEach(DiskBus.available(for: wizard.effectiveArch)) { Text(verbatim: $0.title).tag($0) }
                }
                Stepper(value: binding.device, in: 0...(disk.bus.maxDevices - 1)) {
                    LabeledContent("设备", value: "\(disk.device)")
                }
                if disk.bus == .scsi {
                    LabeledContent("SCSI 控制器", value: QemuWizardOptions.scsiControllerTitle(wizard.scsihw))
                }
                if disk.isImport {
                    StoragePickerRow(title: "导入存储", storages: data.storages("import"), selection: binding.importStorage)
                    VolumePickerRow(title: "选择镜像", data: data, node: wizard.node, storage: disk.importStorage, content: "import", selection: binding.importFrom) { item in
                        ["qcow2", "vmdk", "raw"].contains(item.format ?? "")
                    }
                }
                DiskTargetRows(storageTitle: disk.isImport ? "目标存储" : "存储", data: data, node: wizard.node, target: binding.target)
                if !disk.isImport && !disk.target.selectExisting {
                    OptionalDoubleField(title: "磁盘大小 (GiB)", value: Binding(get: { binding.wrappedValue.size }, set: { binding.wrappedValue.size = $0 ?? 0 }))
                }
                OptionPicker(title: "缓存", options: QemuWizardOptions.cache, selection: binding.cache)
                Toggle("丢弃", isOn: binding.discard)
                Toggle("IO 线程", isOn: binding.iothread)
                    .disabled(!disk.supportsIOThread)
            }
            .onAppear {
                if disk.isImport && disk.importStorage.isEmpty, let first = data.storages("import").first {
                    binding.wrappedValue.importStorage = first.storage
                }
            }
            if advanced {
                Section("高级") {
                    Toggle("SSD 仿真", isOn: binding.ssd).disabled(!disk.supportsSSD)
                    Toggle("只读", isOn: binding.readOnly).disabled(!disk.supportsReadOnly)
                    Toggle("备份", isOn: binding.backup)
                    Toggle("跳过复制", isOn: binding.skipReplication)
                    OptionPicker(title: "异步 IO", options: QemuWizardOptions.aio, selection: binding.aio)
                }
            }
        } else {
            Section {
                OptionalDoubleField(title: "读取限制 (MB/s)", value: binding.mbpsRd, prompt: "unlimited")
                OptionalDoubleField(title: "写入限制 (MB/s)", value: binding.mbpsWr, prompt: "unlimited")
                OptionalIntField(title: "读取限制 (ops/s)", value: binding.iopsRd, prompt: "unlimited")
                OptionalIntField(title: "写入限制 (ops/s)", value: binding.iopsWr, prompt: "unlimited")
                OptionalDoubleField(title: "最大突发读取 (MB)", value: binding.mbpsRdMax, prompt: "default")
                OptionalDoubleField(title: "最大突发写入 (MB)", value: binding.mbpsWrMax, prompt: "default")
                OptionalIntField(title: "最大突发读取 (ops)", value: binding.iopsRdMax, prompt: "default")
                OptionalIntField(title: "最大突发写入 (ops)", value: binding.iopsWrMax, prompt: "default")
            } footer: {
                Text("留空表示不限制。")
            }
        }
    }

    // MARK: CPU, memory, network

    @ViewBuilder
    private var cpuStep: some View {
        Section {
            Stepper(value: $wizard.sockets, in: 1...64) {
                LabeledContent("CPU 插槽数", value: "\(wizard.sockets)")
            }
            Stepper(value: $wizard.cores, in: 1...256) {
                LabeledContent("核心", value: "\(wizard.cores)")
            }
            Picker("类型", selection: $wizard.cputype) {
                Text("默认 (\(QemuWizardOptions.defaultCPUType(for: wizard.effectiveArch)))").tag("")
                ForEach(data.cpuModels) { model in
                    Text(verbatim: "\(model.displayName) · \(model.vendorTitle)").tag(model.name)
                }
            }
            LabeledContent("核心总数", value: "\(wizard.totalCores)")
        }
        if advanced {
            Section("高级") {
                OptionalIntField(title: "VCPUs", value: $wizard.vcpus, prompt: "\(wizard.totalCores)")
                OptionalDoubleField(title: "CPU 限制", value: $wizard.cpulimit, prompt: String(localized: "无限制"))
                LabeledContent("CPU 绑定") {
                    TextField(String(localized: "所有核心"), text: $wizard.affinity)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .disabled(!wizard.isRootUser)
                }
                OptionalIntField(title: "CPU 权重", value: $wizard.cpuunits, prompt: "\(wizard.defaultCPUUnits)")
                Toggle("启用 NUMA", isOn: $wizard.numa)
            }
            Section {
                Toggle("仅显示至少一个节点支持的标志", isOn: $onlySupportedFlags)
                ForEach(data.cpuFlags.filter { !onlySupportedFlags || $0.isCommonlySupported || wizard.flags[$0.name].map { $0 != .default } == true }) { flag in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(verbatim: flag.name).font(.callout.monospaced())
                            Spacer()
                            Picker("", selection: Binding(get: { wizard.flags[flag.name] ?? .default }, set: { wizard.flags[flag.name] = $0 })) {
                                Text("关闭").tag(CPUFlagState.off)
                                Text("默认").tag(CPUFlagState.default)
                                Text("启用").tag(CPUFlagState.on)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 180)
                        }
                        if !flag.description.isEmpty {
                            Text(verbatim: flag.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("额外 CPU 标志")
            } footer: {
                Text("显示 KVM 下的标志。")
            }
        }
    }

    @ViewBuilder
    private var memoryStep: some View {
        Section {
            IntField(title: "内存 (MiB)", value: Binding(get: { wizard.memory }, set: { wizard.setMemory($0) }))
        }
        if advanced {
            Section("高级") {
                Toggle("Ballooning 设备", isOn: $wizard.ballooning)
                IntField(title: "最小内存 (MiB)", value: $wizard.balloon)
                    .disabled(!wizard.ballooning)
                OptionalIntField(title: "共享", value: $wizard.shares, prompt: String(localized: "默认 (1000)"))
                    .disabled(!wizard.ballooning || wizard.balloon == wizard.memory)
                Toggle("允许 KSM", isOn: $wizard.allowKSM)
            }
        }
    }

    @ViewBuilder
    private var networkStep: some View {
        Section {
            Toggle("无网络设备", isOn: $wizard.noNetwork)
            Group {
                Picker("桥接", selection: $wizard.bridge) {
                    if wizard.bridge.isEmpty { Text("请选择").tag("") }
                    ForEach(data.bridges, id: \.self) { Text(verbatim: $0).tag($0) }
                }
                OptionalIntField(title: "VLAN 标签", value: $wizard.vlanTag, prompt: String(localized: "无 VLAN"))
                Toggle("防火墙", isOn: $wizard.firewall)
                OptionPicker(title: "型号", options: QemuWizardOptions.networkCards, selection: $wizard.model)
                LabeledContent("MAC 地址") {
                    TextField("auto", text: $wizard.macAddress)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .disabled(wizard.noNetwork)
        }
        if advanced {
            Section {
                Toggle("断开", isOn: $wizard.disconnect)
                OptionalIntField(title: "MTU", value: $wizard.mtu, prompt: String(localized: "与网桥相同"))
                    .disabled(wizard.model != "virtio")
                OptionalDoubleField(title: "速率限制 (MB/s)", value: $wizard.rate, prompt: "unlimited")
                OptionalIntField(title: "Multiqueue", value: $wizard.queues)
            } header: {
                Text("高级")
            } footer: {
                if wizard.mtu == 1 { Text("特殊值 1 表示继承网桥的 MTU。") }
            }
            .disabled(wizard.noNetwork)
        }
    }

    @ViewBuilder
    private var confirmStep: some View {
        let missing = connection.missing(needs)
        ForEach(VMWizardStep.allCases.filter { $0 != .confirm }) { group in
            WizardConfirmGroup(title: group.title, settings: wizard.settings(for: group)) { go(to: group) }
        }
        if !missing.isEmpty {
            Section { MissingPermissionLabel(action: "创建虚拟机", missing: missing) }
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
            try await client.createVM(request)
        }
        switch result {
        case .success(let upid):
            onCreated(TrackedTask(upid: upid, title: String(localized: "新建虚拟机 \(String(request.vmid ?? 0))")))
        case .failure(let failure):
            createError = failure.message
        }
    }
}

extension QemuOSBase {
    var title: String {
        switch self {
        case .linux: return "Linux"
        case .windows: return "Microsoft Windows"
        case .solaris: return "Solaris Kernel"
        case .other: return String(localized: "其他")
        }
    }
}
