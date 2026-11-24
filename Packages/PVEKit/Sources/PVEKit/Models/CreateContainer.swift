import Foundation

// Create CT wizard (`PVE.lxc.CreateWizard`), as in docs/create-wizard-fields.md §4.

public enum CTWizardStep: Int, Sendable, Hashable, CaseIterable, Identifiable {
    case general, template, disks, cpu, memory, network, dns, confirm
    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .general: return "常规"
        case .template: return "模板"
        case .disks: return "磁盘"
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .dns: return "DNS"
        case .confirm: return "确认"
        }
    }
}

/// One row of the ID mapping table (`u`/`g`, container ID, host ID, range size).
public struct IDMapRow: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var type: String = "u"
    public var containerID: Int?
    public var hostID: Int?
    public var size: Int?

    public init(type: String = "u", containerID: Int? = nil, hostID: Int? = nil, size: Int? = nil) {
        self.type = type
        self.containerID = containerID
        self.hostID = hostID
        self.size = size
    }

    /// Only complete rows are submitted.
    public var value: String? {
        guard let containerID, let hostID, let size, containerID >= 0, hostID >= 0, size >= 1 else { return nil }
        return "\(type):\(containerID):\(hostID):\(size)"
    }
}

/// `rootfs` or a mount point `mpN` of the 「磁盘」 step (`pveLxcMountPointInputPanel`).
public struct CTMountDraft: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var isRoot: Bool
    public var mpid: Int
    public var storage = ""
    public var storageType = ""
    /// GiB.
    public var size: Double = 8
    public var path = ""
    public var backup = true
    public var quota = false
    public var readOnly = false
    public var mountOptions: [String] = []
    /// nil = default, true = enabled, false = disabled.
    public var acl: Bool?
    public var skipReplication = false
    public var keepAttributes = false
    public var idmapPassthrough = false
    public var idmap: [IDMapRow] = []

    public init(isRoot: Bool, mpid: Int = 0) {
        self.isRoot = isRoot
        self.mpid = mpid
    }

    public var key: String { isRoot ? "rootfs" : "mp\(mpid)" }

    public static let rootMountOptions = ["discard", "lazytime", "noatime", "nosuid"]
    public static let mountPointOptions = ["discard", "lazytime", "noatime", "nodev", "noexec", "nosuid"]
    public var availableMountOptions: [String] { isRoot ? Self.rootMountOptions : Self.mountPointOptions }

    /// Quota is unavailable on ZFS and for unprivileged containers.
    public func quotaAvailable(unprivileged: Bool) -> Bool {
        !unprivileged && storageType != "zfs" && storageType != "zfspool"
    }

    public var idmapValue: String? {
        if idmapPassthrough { return "passthrough" }
        let rows = idmap.compactMap(\.value)
        return rows.isEmpty ? nil : rows.joined(separator: ";")
    }

    /// `printLxcMountPoint` order.
    public func configString(unprivileged: Bool) -> String {
        var parts = ["\(storage):\(WizardValidation.number(size))"]
        if !isRoot { parts.append("mp=\(path.trimmingCharacters(in: .whitespaces))") }
        let options = mountOptions.filter { availableMountOptions.contains($0) }
        if !options.isEmpty { parts.append("mountoptions=\(options.joined(separator: ";"))") }
        if !isRoot && backup { parts.append("backup=1") }
        if quota && quotaAvailable(unprivileged: unprivileged) { parts.append("quota=1") }
        if !isRoot && readOnly { parts.append("ro=1") }
        if let acl { parts.append("acl=\(acl ? 1 : 0)") }
        if skipReplication { parts.append("replicate=0") }
        if !isRoot && keepAttributes { parts.append("keepattrs=1") }
        if let idmapValue { parts.append("idmap=\(idmapValue)") }
        return parts.joined(separator: ",")
    }
}

public enum IPv4Mode: String, Sendable, Hashable, CaseIterable, Identifiable {
    case `static`, dhcp
    public var id: String { rawValue }
}

public enum IPv6Mode: String, Sendable, Hashable, CaseIterable, Identifiable {
    case `static`, dhcp, auto
    public var id: String { rawValue }
}

/// Everything the Create CT wizard collects.
public struct CTWizard: Sendable, Hashable {
    public var node = ""
    public var nodeArch = "amd64"
    public var cgroupMode = 2

    // General.
    public var vmid: Int?
    public var hostname = ""
    public private(set) var unprivileged = true
    public var nesting = true
    public var haManaged = false
    public var pool = ""
    public var password = ""
    public var confirmPassword = ""
    public var sshKeys = ""
    public var tags: [String] = []

    // Template.
    public var templateStorage = ""
    public var ostemplate = ""
    public var showAllArchitectures = false

    // Disks.
    public var mounts: [CTMountDraft] = [CTMountDraft(isRoot: true)]

    // CPU.
    public var cores: Int? = 1
    public var cpulimit: Double?
    public var cpuunits: Int?

    // Memory.
    public var memory = 512
    public var swap = 512

    // Network.
    public var interfaceName = "eth0"
    public var hwaddr = ""
    public var bridge = ""
    public var vlanTag: Int?
    public var firewall = true
    public var ipv4Mode: IPv4Mode = .static
    public var ipv4 = ""
    public var gateway4 = ""
    public var ipv6Mode: IPv6Mode = .static
    public var ipv6 = ""
    public var gateway6 = ""
    public var linkDown = false
    public var mtu: Int?
    public var rate: Double?
    public var hostManaged = false

    // DNS.
    public var searchDomain = ""
    public var nameservers = ""

    // Confirm.
    public var start = false

    public init() {}

    /// Unchecking 「无特权的容器」 clears and disables Nesting; checking it again does not restore it.
    public mutating func setUnprivileged(_ value: Bool) {
        unprivileged = value
        if !value { nesting = false }
        for index in mounts.indices where !mounts[index].quotaAvailable(unprivileged: value) {
            mounts[index].quota = false
        }
    }

    public var defaultCPUUnits: Int { cgroupMode == 1 ? 1024 : 100 }
    public var cpuUnitsRange: ClosedRange<Int> { cgroupMode == 1 ? 8...500_000 : 8...10_000 }

    /// `mpN` with the smallest free N.
    @discardableResult
    public mutating func addMountPoint(storage: NodeStorage?) -> UUID? {
        let taken = Set(mounts.filter { !$0.isRoot }.map(\.mpid))
        guard let free = (0...255).first(where: { !taken.contains($0) }) else { return nil }
        var mount = CTMountDraft(isRoot: false, mpid: free)
        if let storage {
            mount.storage = storage.storage
            mount.storageType = storage.type
        }
        mounts.append(mount)
        return mount.id
    }

    public var sortedMounts: [CTMountDraft] {
        mounts.sorted { lhs, rhs in
            if lhs.isRoot != rhs.isRoot { return lhs.isRoot }
            return lhs.mpid < rhs.mpid
        }
    }

    /// Architecture in a template file name (`…_amd64.tar.zst`); nil when not recognised.
    public static func templateArch(_ volid: String) -> String? {
        guard let range = volid.range(of: #"_([a-z][a-z0-9]*)\.tar(?:\.\w+)?$"#, options: .regularExpression) else { return nil }
        let match = volid[range].dropFirst()
        let arch = match.prefix { $0 != "." }
        return ["amd64", "arm64", "i386", "riscv64"].contains(String(arch)) ? String(arch) : nil
    }

    /// Templates hidden by the architecture filter unless 「显示所有架构」 is on.
    public func showsTemplate(_ volid: String) -> Bool {
        guard !showAllArchitectures, let arch = Self.templateArch(volid) else { return true }
        return arch == nodeArch
    }

    public var net0: String {
        var parts: [String] = []
        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { parts.append("\(key)=\(value)") }
        }
        add("name", interfaceName.trimmingCharacters(in: .whitespaces))
        add("hwaddr", hwaddr.trimmingCharacters(in: .whitespaces))
        add("bridge", bridge)
        add("tag", vlanTag.map(String.init))
        if firewall { parts.append("firewall=1") }
        switch ipv4Mode {
        case .dhcp: parts.append("ip=dhcp")
        case .static:
            add("ip", ipv4.trimmingCharacters(in: .whitespaces))
            add("gw", gateway4.trimmingCharacters(in: .whitespaces))
        }
        switch ipv6Mode {
        case .dhcp: parts.append("ip6=dhcp")
        case .auto: parts.append("ip6=auto")
        case .static:
            add("ip6", ipv6.trimmingCharacters(in: .whitespaces))
            add("gw6", gateway6.trimmingCharacters(in: .whitespaces))
        }
        if linkDown { parts.append("link_down=1") }
        add("mtu", mtu.map(String.init))
        add("rate", rate.map(WizardValidation.number))
        if hostManaged { parts.append("host-managed=1") }
        return parts.joined(separator: ",")
    }

    /// `POST /nodes/{node}/lxc`.
    public func request() -> PVEAPI.PostNodesLxc {
        var request = PVEAPI.PostNodesLxc(node: node, ostemplate: ostemplate, vmid: vmid ?? 0)
        let name = hostname.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { request.hostname = name }
        request.unprivileged = unprivileged
        if unprivileged && nesting { request.features = "nesting=1" }
        if haManaged { request.haManaged = true }
        if !pool.isEmpty { request.pool = pool }
        if !password.isEmpty { request.password = password }
        let keys = sshKeys.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keys.isEmpty { request.sshPublicKeys = keys }
        if !tags.isEmpty { request.tags = tags.joined(separator: ";") }
        for mount in mounts {
            if mount.isRoot {
                request.rootfs = mount.configString(unprivileged: unprivileged)
            } else {
                request.mp[mount.mpid] = mount.configString(unprivileged: unprivileged)
            }
        }
        request.cores = cores
        if let cpulimit, cpulimit != 0 { request.cpulimit = cpulimit }
        if let cpuunits, cpuunits != defaultCPUUnits { request.cpuunits = cpuunits }
        request.memory = memory
        request.swap = swap
        request.net[0] = net0
        let domain = searchDomain.trimmingCharacters(in: .whitespaces)
        if !domain.isEmpty { request.searchdomain = domain }
        let servers = WizardValidation.splitAddressList(nameservers)
        if !servers.isEmpty { request.nameserver = servers.joined(separator: " ") }
        if start { request.start = true }
        return request
    }

    /// Confirm page settings per step (the password is never shown).
    public func settings(for step: CTWizardStep) -> [WizardSetting] {
        let parameters = Dictionary(request().parameters, uniquingKeysWith: { _, last in last })
        let keys: [String]
        switch step {
        case .general: keys = ["vmid", "hostname", "unprivileged", "features", "ha-managed", "pool", "ssh-public-keys", "tags"]
        case .template: keys = ["ostemplate"]
        case .disks: keys = sortedMounts.map(\.key)
        case .cpu: keys = ["cores", "cpulimit", "cpuunits"]
        case .memory: keys = ["memory", "swap"]
        case .network: keys = ["net0"]
        case .dns: keys = ["searchdomain", "nameserver"]
        case .confirm: keys = ["start"]
        }
        var result: [WizardSetting] = []
        if step == .general {
            result.append(WizardSetting("nodename", node))
        }
        for key in keys {
            if let value = parameters[key] { result.append(WizardSetting(key, value)) }
        }
        if step == .general && !password.isEmpty { result.append(WizardSetting("password", "••••••")) }
        return result
    }

    public func problems(_ step: CTWizardStep) -> [WizardProblem] {
        var problems: [WizardProblem] = []
        switch step {
        case .general:
            if node.isEmpty { problems.append(WizardProblem("nodename", "请选择节点")) }
            if !VMID.isValid(vmid) { problems.append(WizardProblem("vmid", "CT ID 须为 100–999999999 之间的整数")) }
            let name = hostname.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !WizardValidation.isDNSName(name) { problems.append(WizardProblem("hostname", "该主机名无效")) }
            let keys = sshKeys.trimmingCharacters(in: .whitespacesAndNewlines)
            if keys.isEmpty && password.isEmpty { problems.append(WizardProblem("password", "请设置密码或填写 SSH 公钥")) }
            if !password.isEmpty && password.count < 5 { problems.append(WizardProblem("password", "密码至少 5 个字符")) }
            if password != confirmPassword { problems.append(WizardProblem("confirmpw", "密码不匹配！")) }
            if !keys.isEmpty && !WizardValidation.areSSHKeys(keys) { problems.append(WizardProblem("ssh-public-keys", "无法识别 SSH 公钥")) }
            if tags.contains(where: { !WizardValidation.isTag($0) }) { problems.append(WizardProblem("tags", "标签包含无效字符。")) }
        case .template:
            if templateStorage.isEmpty { problems.append(WizardProblem("tmplstorage", "请选择存储")) }
            if ostemplate.isEmpty { problems.append(WizardProblem("ostemplate", "请选择模板")) }
        case .disks:
            var used: Set<Int> = []
            for mount in sortedMounts {
                let field = "mount:\(mount.id.uuidString)"
                if mount.storage.isEmpty { problems.append(WizardProblem(field, "\(mount.key)：请选择存储")) }
                if !(0.001...131_072).contains(mount.size) { problems.append(WizardProblem(field, "\(mount.key)：磁盘大小须在 0.001–131072 GiB 之间")) }
                if !mount.isRoot {
                    if !(0...255).contains(mount.mpid) { problems.append(WizardProblem(field, "\(mount.key)：挂载点 ID 须在 0–255 之间")) }
                    if used.contains(mount.mpid) { problems.append(WizardProblem(field, "\(mount.key)：挂载点已被使用。")) }
                    used.insert(mount.mpid)
                    if mount.path.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(WizardProblem(field, "\(mount.key)：请填写路径")) }
                }
            }
        case .cpu:
            if let cores, !(1...8192).contains(cores) { problems.append(WizardProblem("cores", "核心数须在 1–8192 之间")) }
            if let cpulimit, cpulimit < 0 { problems.append(WizardProblem("cpulimit", "CPU 限制不能为负数")) }
            if let cpuunits, !cpuUnitsRange.contains(cpuunits) { problems.append(WizardProblem("cpuunits", "CPU 权重须在 \(cpuUnitsRange.lowerBound)–\(cpuUnitsRange.upperBound) 之间")) }
        case .memory:
            if memory < 16 { problems.append(WizardProblem("memory", "内存至少 16 MiB")) }
            if swap < 0 { problems.append(WizardProblem("swap", "Swap 不能为负数")) }
        case .network:
            if interfaceName.trimmingCharacters(in: .whitespaces).isEmpty { problems.append(WizardProblem("name", "请填写名称")) }
            let mac = hwaddr.trimmingCharacters(in: .whitespaces)
            if !mac.isEmpty && !WizardValidation.isMAC(mac) { problems.append(WizardProblem("hwaddr", "MAC 地址格式无效")) }
            if bridge.isEmpty { problems.append(WizardProblem("bridge", "请选择网桥")) }
            if let vlanTag, !(1...4094).contains(vlanTag) { problems.append(WizardProblem("tag", "VLAN 标签须在 1–4094 之间")) }
            if ipv4Mode == .static {
                let ip = ipv4.trimmingCharacters(in: .whitespaces)
                if !ip.isEmpty && !WizardValidation.isIPv4CIDR(ip) { problems.append(WizardProblem("ip", "IPv4/CIDR 格式无效，例如 192.168.1.50/24")) }
                let gw = gateway4.trimmingCharacters(in: .whitespaces)
                if !gw.isEmpty && !WizardValidation.isIPv4(gw) { problems.append(WizardProblem("gw", "IPv4 网关格式无效")) }
            }
            if ipv6Mode == .static {
                let ip = ipv6.trimmingCharacters(in: .whitespaces)
                if !ip.isEmpty && !WizardValidation.isIPv6CIDR(ip) { problems.append(WizardProblem("ip6", "IPv6/CIDR 格式无效，例如 2001:db8::50/64")) }
                let gw = gateway6.trimmingCharacters(in: .whitespaces)
                if !gw.isEmpty && !WizardValidation.isIPv6(gw) { problems.append(WizardProblem("gw6", "IPv6 网关格式无效")) }
            }
            if let mtu, !(576...65_535).contains(mtu) { problems.append(WizardProblem("mtu", "MTU 须在 576–65535 之间")) }
            if let rate, !(0...10_240).contains(rate) { problems.append(WizardProblem("rate", "速率限制须在 0–10240 MB/s 之间")) }
        case .dns:
            let servers = nameservers.trimmingCharacters(in: .whitespaces)
            if !servers.isEmpty && !WizardValidation.isAddressList(servers) {
                problems.append(WizardProblem("nameserver", "DNS 服务器格式无效，例如 192.168.1.1,192.168.1.2"))
            }
        case .confirm:
            break
        }
        return problems
    }
}
