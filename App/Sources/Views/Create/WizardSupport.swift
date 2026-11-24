import PVEKit
import SwiftUI

enum CreateGuestKind: String, Identifiable {
    case vm, ct
    var id: String { rawValue }
}

/// 「新建虚拟机」/「新建容器」 wizard, replicating the WebUI wizards step by step
/// (docs/create-wizard-fields.md).
struct CreateGuestWizard: View {
    let connection: ServerConnection
    let kind: CreateGuestKind
    let presetNode: String?
    let onCreated: (TrackedTask) -> Void

    var body: some View {
        switch kind {
        case .vm: VMCreateWizard(connection: connection, presetNode: presetNode, onCreated: onCreated)
        case .ct: CTCreateWizard(connection: connection, presetNode: presetNode, onCreated: onCreated)
        }
    }
}

/// The WebUI's global 「高级」 checkbox state (same key as the browser state).
enum WizardPreferences {
    static let advancedKey = "proxmox-advanced-cb"
}

/// Data the wizards load from the server: nodes, storages, bridges, pools, volumes, CPU models.
@MainActor
@Observable
final class WizardData {
    let connection: ServerConnection
    var nodes: [WizardNode] = []
    var pools: [String] = []
    var tags: [String] = []
    var bridges: [String] = []
    var storages: [String: [NodeStorage]] = [:]
    var volumes: [String: [StorageContentItem]] = [:]
    var cpuModels: [CPUModel] = []
    var cpuFlags: [CPUFlag] = []
    var loadError: String?
    /// VMID availability: nil unknown / checking.
    var vmidFree: Bool?
    var nextVMID: Int?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    var client: PVEClient { connection.client }

    func loadCommon() async {
        do {
            nodes = try await client.wizardNodes()
            loadError = nil
        } catch {
            connection.absorb(error)
            loadError = ErrorText.message(for: error)
        }
        nextVMID = try? await client.nextVMID()
        pools = (try? await client.pools()) ?? []
        tags = (try? await client.allowedTags()) ?? []
        await connection.loadPermissions(path: "/vms")
    }

    /// Storages and bridges of a node (all content types the wizards use).
    func loadNode(_ node: String, contents: [String]) async {
        guard !node.isEmpty else { return }
        bridges = (try? await client.bridges(node: node)) ?? []
        for content in contents {
            storages[content] = ((try? await client.nodeStorages(node: node, content: content)) ?? []).filter { storage in
                storage.active && Self.contentAllows(storage.content, content)
            }
        }
    }

    /// `contentAllows`: `images` also matches `vm-vol` / `vm-state`, `rootdir` matches `ct-vol`.
    static func contentAllows(_ content: Set<String>, _ type: String) -> Bool {
        let generic = ["vm-vol": "images", "vm-state": "images", "ct-vol": "rootdir"]
        return content.contains { $0 == type || generic[$0] == type || generic[type] == $0 }
    }

    func storages(_ content: String) -> [NodeStorage] { storages[content] ?? [] }

    func storage(_ name: String, content: String) -> NodeStorage? {
        storages(content).first { $0.storage == name }
    }

    func volumes(node: String, storage: String, content: String) -> [StorageContentItem] {
        volumes["\(node)|\(storage)|\(content)"] ?? []
    }

    func loadVolumes(node: String, storage: String, content: String) async {
        guard !node.isEmpty, !storage.isEmpty else { return }
        let key = "\(node)|\(storage)|\(content)"
        volumes[key] = (try? await client.storageVolumes(node: node, storage: storage, content: content)) ?? []
    }

    func loadCPU(arch: GuestArch) async {
        cpuModels = (try? await client.cpuModels(arch: arch)) ?? []
        cpuFlags = (try? await client.cpuFlags(arch: arch)) ?? []
    }

    func checkVMID(_ vmid: Int?) async {
        vmidFree = nil
        guard let vmid, VMID.isValid(vmid) else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        vmidFree = try? await client.isVMIDFree(vmid)
        await connection.loadPermissions(path: PermissionNeed.vm(vmid))
    }
}

/// Horizontally scrolling step bar: completed, current and not yet reached steps.
struct WizardStepBar: View {
    let titles: [String]
    let current: Int
    let reached: Int
    let onSelect: (Int) -> Void
    @Environment(\.chelateAccent) private var accent

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                        Button { onSelect(index) } label: {
                            HStack(spacing: 4) {
                                if index < current || (index <= reached && index != current) {
                                    Image(systemName: "checkmark.circle.fill")
                                } else {
                                    Text(verbatim: "\(index + 1)").monospacedDigit()
                                }
                                Text(verbatim: title)
                            }
                            .font(.subheadline.weight(index == current ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(foreground(index))
                            .background(background(index), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(index > reached)
                        .id(index)
                        .accessibilityIdentifier("wizard-step-\(index)")
                        .accessibilityAddTraits(index == current ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: current) { _, value in
                withAnimation { proxy.scrollTo(value, anchor: .center) }
            }
        }
    }

    private func foreground(_ index: Int) -> AnyShapeStyle {
        if index == current { return AnyShapeStyle(Color.white) }
        if index <= reached { return AnyShapeStyle(accent) }
        return AnyShapeStyle(.secondary)
    }

    private func background(_ index: Int) -> AnyShapeStyle {
        if index == current { return AnyShapeStyle(accent) }
        if index <= reached { return AnyShapeStyle(accent.opacity(0.14)) }
        return AnyShapeStyle(Color.secondary.opacity(0.12))
    }
}

/// 「上一步 / 下一步」 bar; on the confirm page 「创建后启动」 and 「创建」.
struct WizardBottomBar: View {
    let isFirst: Bool
    let isConfirm: Bool
    let canAdvance: Bool
    let creating: Bool
    @Binding var start: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if isConfirm {
                Toggle("创建后启动", isOn: $start)
                    .accessibilityIdentifier("wizard-start")
            }
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text("上一步").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isFirst)
                .accessibilityIdentifier("wizard-back")
                if isConfirm {
                    Button(action: onCreate) {
                        Group {
                            if creating { ProgressView() } else { Text("创建") }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance || creating)
                    .accessibilityIdentifier("wizard-create")
                } else {
                    Button(action: onNext) {
                        Text("下一步").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
                    .accessibilityIdentifier("wizard-next")
                }
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// Problems of the current step, shown in place.
struct WizardProblemsSection: View {
    let problems: [WizardProblem]

    var body: some View {
        if !problems.isEmpty {
            Section {
                ForEach(problems) { problem in
                    Label(problem.message, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .accessibilityIdentifier("wizard-problems")
        }
    }
}

/// One group of the confirm page; tapping it jumps back to the step.
struct WizardConfirmGroup: View {
    let title: String
    let settings: [WizardSetting]
    let onEdit: () -> Void

    var body: some View {
        Section {
            if settings.isEmpty {
                Text("使用默认值").foregroundStyle(.secondary)
            }
            ForEach(settings) { setting in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: setting.key)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: setting.value.isEmpty ? "–" : setting.value)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } header: {
            Button(action: onEdit) {
                HStack {
                    Text(verbatim: title)
                    Spacer()
                    Text("修改").textCase(nil)
                    Image(systemName: "chevron.right")
                }
                .font(.subheadline)
            }
            .accessibilityIdentifier("confirm-group-\(title)")
        }
    }
}

// MARK: - Field helpers

/// Storage picker with an optional 「请选择」 row.
struct StoragePickerRow: View {
    let title: LocalizedStringKey
    let storages: [NodeStorage]
    @Binding var selection: String
    var allowsEmpty = false
    var emptyTitle: LocalizedStringKey = "请选择"

    var body: some View {
        Picker(title, selection: $selection) {
            if allowsEmpty || selection.isEmpty || !storages.contains(where: { $0.storage == selection }) {
                Text(emptyTitle).tag("")
            }
            ForEach(storages) { storage in
                Text(verbatim: storage.storage).tag(storage.storage)
            }
        }
    }
}

/// File picker (ISO images, templates, import images, existing volumes) of one storage.
struct VolumePickerRow: View {
    let title: LocalizedStringKey
    let data: WizardData
    let node: String
    let storage: String
    let content: String
    @Binding var selection: String
    var filter: (StorageContentItem) -> Bool = { _ in true }

    var body: some View {
        let items = data.volumes(node: node, storage: storage, content: content).filter(filter)
        Picker(title, selection: $selection) {
            Text("请选择").tag("")
            ForEach(items) { item in
                Text(verbatim: item.fileName).tag(item.volid)
            }
        }
        .task(id: "\(node)|\(storage)|\(content)") {
            await data.loadVolumes(node: node, storage: storage, content: content)
        }
    }
}

/// Storage + (select_existing) volume + format, for VM disks, the EFI disk and the TPM.
struct DiskTargetRows: View {
    let storageTitle: LocalizedStringKey
    let data: WizardData
    let node: String
    @Binding var target: DiskTarget

    var body: some View {
        StoragePickerRow(title: storageTitle, storages: data.storages("images"), selection: Binding(
            get: { target.storage },
            set: { name in
                if let storage = data.storage(name, content: "images") { target.select(storage) } else { target.storage = name }
            }
        ))
        if target.selectExisting {
            VolumePickerRow(title: "磁盘映像", data: data, node: node, storage: target.storage, content: "images", selection: Binding(
                get: { target.existingVolume ?? "" },
                set: { target.existingVolume = $0.isEmpty ? nil : $0 }
            ))
        }
        if let storage = data.storage(target.storage, content: "images"), storage.offersFormatChoice, !target.selectExisting {
            Picker("格式", selection: Binding(get: { target.format ?? storage.preferredFormat }, set: { target.format = $0 })) {
                ForEach(storage.formatChoices) { format in
                    Text(CloneView.formatTitle(format)).tag(format)
                }
            }
        } else {
            LabeledContent("格式", value: "raw")
                .foregroundStyle(.secondary)
        }
    }
}

/// Tag editor: chips, a text field and suggestions from `allowed-tags`.
struct TagEditorRows: View {
    @Binding var tags: [String]
    let suggestions: [String]
    @State private var input = ""

    var body: some View {
        if !tags.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Button {
                            tags.removeAll { $0 == tag }
                        } label: {
                            HStack(spacing: 4) {
                                Text(verbatim: tag)
                                Image(systemName: "xmark.circle.fill")
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        HStack {
            TextField("添加标签", text: $input)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(add)
            Button("添加", action: add)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        let remaining = suggestions.filter { !tags.contains($0) }
        if !remaining.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(remaining, id: \.self) { tag in
                        Button(tag) { tags.append(tag) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func add() {
        for tag in input.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }).map(String.init) where !tags.contains(tag) {
            tags.append(tag)
        }
        input = ""
    }
}

/// `Picker` over `(value, title)` pairs.
struct OptionPicker: View {
    let title: LocalizedStringKey
    let options: [(String, String)]
    @Binding var selection: String

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.0) { option in
                Text(verbatim: option.1).tag(option.0)
            }
        }
    }
}
