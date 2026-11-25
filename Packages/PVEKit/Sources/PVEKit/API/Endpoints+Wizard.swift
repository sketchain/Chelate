import Foundation

/// A node as the create wizards need it: online state, CPU architecture and cgroup version.
public struct WizardNode: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var online: Bool
    public var arch: GuestArch
    /// 1 or 2 (`cgroup-mode`, missing = 2).
    public var cgroupMode: Int

    public init(name: String, online: Bool, arch: GuestArch = .x86_64, cgroupMode: Int = 2) {
        self.name = name
        self.online = online
        self.arch = arch
        self.cgroupMode = cgroupMode
    }

    /// Debian architecture name used in CT template file names.
    public var debianArch: String { arch == .aarch64 ? "arm64" : "amd64" }
}

/// A CPU model of `capabilities/qemu/cpu`, named and ordered like `CPUModelSelector`.
public struct CPUModel: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var vendor: String
    public var custom: Bool

    public init(name: String, vendor: String, custom: Bool) {
        self.name = name
        self.vendor = vendor
        self.custom = custom
    }

    /// `custom-` prefix removed.
    public var displayName: String { name.hasPrefix("custom-") ? String(name.dropFirst("custom-".count)) : name }

    public var vendorTitle: String {
        if custom { return "Custom (\(Self.vendorName(vendor)))" }
        if name == "host" { return "Host" }
        return Self.vendorName(vendor)
    }

    static func vendorName(_ vendor: String) -> String {
        switch vendor {
        case "AuthenticAMD": return "AMD"
        case "GenuineIntel": return "Intel"
        case "default": return "QEMU"
        default: return vendor
        }
    }

    /// AMD < Intel < QEMU < Host < others / custom, then name.
    var order: Int {
        if custom { return 5 }
        if name == "host" { return 4 }
        switch vendor {
        case "AuthenticAMD": return 1
        case "GenuineIntel": return 2
        case "default": return 3
        default: return 5
        }
    }

    public static func sorted(_ models: [CPUModel]) -> [CPUModel] {
        models.sorted { ($0.order, $0.name) < ($1.order, $1.name) }
    }
}

public struct CPUFlag: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var supportedOn: [String]

    /// Shown by default: supported by at least one node, or `nested-virt`.
    public var isCommonlySupported: Bool { !supportedOn.isEmpty || name == "nested-virt" }
}

extension PVEClient {
    /// `GET /nodes` joined with the node entries of `/cluster/resources` (`host-arch`,
    /// `cgroup-mode`), sorted by name.
    public func wizardNodes() async throws -> [WizardNode] {
        async let nodes = send(PVEAPI.GetNodes())
        async let resources = send(PVEAPI.GetClusterResources(), as: JSONValue.self)
        var details: [String: (String?, Int?)] = [:]
        if case .array(let items) = (try? await resources) ?? .null {
            for item in items {
                guard case .object(let object) = item, object["type"]?.stringValue == "node", let name = object["node"]?.stringValue else { continue }
                details[name] = (object["host-arch"]?.stringValue, object["cgroup-mode"]?.doubleValue.map { Int($0) })
            }
        }
        return try await nodes.compactMap { item -> WizardNode? in
            guard let name = item.node else { return nil }
            let detail = details[name]
            return WizardNode(name: name, online: item.status == "online", arch: GuestArch(hostArch: detail?.0), cgroupMode: detail?.1 ?? 2)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// CPU models for an architecture (the WebUI asks `localhost`).
    public func cpuModels(arch: GuestArch) async throws -> [CPUModel] {
        var request = PVEAPI.GetNodesCapabilitiesQemuCpu(node: "localhost")
        request.arch = PVEAPI.GetNodesCapabilitiesQemuCpu.Arch(rawValue: arch.rawValue)
        let items = try await send(request)
        return CPUModel.sorted(items.compactMap { item in
            guard let name = item.name else { return nil }
            return CPUModel(name: name, vendor: item.vendor ?? "", custom: item.custom ?? false)
        })
    }

    public func cpuFlags(arch: GuestArch) async throws -> [CPUFlag] {
        var request = PVEAPI.GetNodesCapabilitiesQemuCpuFlags(node: "localhost")
        request.arch = PVEAPI.GetNodesCapabilitiesQemuCpuFlags.Arch(rawValue: arch.rawValue)
        return try await send(request).compactMap { item in
            guard let name = item.name else { return nil }
            return CPUFlag(name: name, description: item.description ?? "", supportedOn: item.supportedOn ?? [])
        }
    }

    /// `allowed-tags` of `/cluster/options` (tag suggestions).
    public func allowedTags() async throws -> [String] {
        try await send(PVEAPI.GetClusterOptions()).allowedTags ?? []
    }

    /// Volumes of a storage for a content type (ISO images, CT templates, import images, existing
    /// volumes), sorted by name.
    public func storageVolumes(node: String, storage: String, content: String) async throws -> [StorageContentItem] {
        var request = PVEAPI.GetNodesStorageContent(node: node, storage: storage)
        request.content = content
        return try await send(request, as: [StorageContentItem].self)
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    public func createVM(_ wizard: VMWizard) async throws -> String {
        try await send(wizard.request(), as: String.self)
    }

    public func createContainer(_ wizard: CTWizard) async throws -> String {
        try await send(wizard.request(), as: String.self)
    }
}
