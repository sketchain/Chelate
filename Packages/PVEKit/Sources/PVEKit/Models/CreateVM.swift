import Foundation

// Create VM wizard (`PVE.qemu.CreateWizard`), field by field as in docs/create-wizard-fields.md §3.

public enum GuestArch: String, Sendable, Hashable, CaseIterable, Identifiable {
    case x86_64, aarch64
    public var id: String { rawValue }

    /// `host-arch` of a node (missing = x86_64).
    public init(hostArch: String?) {
        self = hostArch == "aarch64" ? .aarch64 : .x86_64
    }
}

public enum QemuOSBase: String, Sendable, Hashable, CaseIterable, Identifiable {
    case linux = "Linux"
    case windows = "Microsoft Windows"
    case solaris = "Solaris Kernel"
    case other = "Other"
    public var id: String { rawValue }

    public static func available(for arch: GuestArch) -> [QemuOSBase] {
        arch == .aarch64 ? [.linux, .other] : allCases
    }
}

/// `PVE.Utils.kvm_ostypes`.
public struct QemuOSType: Sendable, Hashable, Identifiable {
    public var id: String { value }
    public var base: QemuOSBase
    public var label: String
    public var value: String

    public static let all: [QemuOSType] = [
        QemuOSType(base: .linux, label: "7.x - 2.6 Kernel", value: "l26"),
        QemuOSType(base: .linux, label: "2.4 Kernel", value: "l24"),
        QemuOSType(base: .windows, label: "11/2022/2025", value: "win11"),
        QemuOSType(base: .windows, label: "10/2016/2019", value: "win10"),
        QemuOSType(base: .windows, label: "8.x/2012/2012r2", value: "win8"),
        QemuOSType(base: .windows, label: "7/2008r2", value: "win7"),
        QemuOSType(base: .windows, label: "Vista/2008", value: "w2k8"),
        QemuOSType(base: .windows, label: "XP/2003", value: "wxp"),
        QemuOSType(base: .windows, label: "2000", value: "w2k"),
        QemuOSType(base: .solaris, label: "-", value: "solaris"),
        QemuOSType(base: .other, label: "-", value: "other"),
    ]

    public static func types(for base: QemuOSBase, arch: GuestArch) -> [QemuOSType] {
        all.filter { $0.base == base && (arch == .x86_64 || ["l26", "other"].contains($0.value)) }
    }

    public static func base(of value: String) -> QemuOSBase {
        all.first { $0.value == value }?.base ?? .other
    }
}

public enum DiskBus: String, Sendable, Hashable, CaseIterable, Identifiable {
    case ide, sata, virtio, scsi
    public var id: String { rawValue }

    public var maxDevices: Int {
        switch self {
        case .ide: return 4
        case .sata: return 6
        case .virtio: return 16
        case .scsi: return 31
        }
    }

    public var title: String {
        switch self {
        case .ide: return "IDE"
        case .sata: return "SATA"
        case .virtio: return "VirtIO Block"
        case .scsi: return "SCSI"
        }
    }

    public static func available(for arch: GuestArch) -> [DiskBus] {
        arch == .aarch64 ? [.sata, .virtio, .scsi] : [.ide, .sata, .virtio, .scsi]
    }
}

/// `PVE.qemu.OSDefaults.getDefaults`.
public struct QemuOSDefaults: Sendable, Hashable {
    public var busType: DiskBus
    public var networkCard: String
    /// "" = default (LSI).
    public var scsihw: String
    public var machine: String?
    public var bios: String?
    public var busPriority: [DiskBus: Int]

    public static func get(ostype: String, arch: GuestArch) -> QemuOSDefaults {
        let genericPriority: [DiskBus: Int] = [.ide: 4, .sata: 3, .scsi: 2, .virtio: 1]
        if arch == .aarch64 {
            if ostype == "l26" {
                return QemuOSDefaults(busType: .scsi, networkCard: "virtio", scsihw: "virtio-scsi-single", machine: nil, bios: "ovmf", busPriority: [.scsi: 4, .virtio: 2, .sata: 2, .ide: 1])
            }
            return QemuOSDefaults(busType: .scsi, networkCard: "e1000", scsihw: "virtio-scsi-single", machine: nil, bios: "ovmf", busPriority: [.scsi: 4, .sata: 3, .virtio: 2, .ide: 1])
        }
        switch ostype {
        case "l26":
            return QemuOSDefaults(busType: .scsi, networkCard: "virtio", scsihw: "virtio-scsi-single", machine: nil, bios: nil, busPriority: [.scsi: 4, .virtio: 3, .sata: 2, .ide: 1])
        case "w2k", "wxp":
            return QemuOSDefaults(busType: .ide, networkCard: "rtl8139", scsihw: "", machine: nil, bios: nil, busPriority: genericPriority)
        case "win11":
            return QemuOSDefaults(busType: .ide, networkCard: "e1000", scsihw: "virtio-scsi-single", machine: "q35", bios: "ovmf", busPriority: genericPriority)
        default:
            return QemuOSDefaults(busType: .ide, networkCard: "e1000", scsihw: "virtio-scsi-single", machine: nil, bios: nil, busPriority: genericPriority)
        }
    }
}

/// Option lists of the VM wizard (value, WebUI label in Chinese).
public enum QemuWizardOptions {
    public static let vga: [(String, String)] = [
        ("__default__", "默认"), ("std", "标准 VGA"), ("vmware", "VMware 兼容"),
        ("qxl", "SPICE"), ("qxl2", "SPICE 双显示器"), ("qxl3", "SPICE 三显示器"), ("qxl4", "SPICE 四显示器"),
        ("serial0", "串行终端 0"), ("serial1", "串行终端 1"), ("serial2", "串行终端 2"), ("serial3", "串行终端 3"),
        ("virtio", "VirtIO-GPU"), ("virtio-gl", "VirGL GPU"), ("none", "无"),
    ]

    public static func machines(for arch: GuestArch) -> [(String, String)] {
        arch == .aarch64 ? [("__default__", "默认 (virt)")] : [("__default__", "默认 (i440fx)"), ("q35", "q35")]
    }

    public static func bioses(for arch: GuestArch) -> [(String, String)] {
        arch == .aarch64 ? [("ovmf", "OVMF (UEFI)")] : [("__default__", "默认 (SeaBIOS)"), ("seabios", "SeaBIOS"), ("ovmf", "OVMF (UEFI)")]
    }

    public static func scsiControllers(for arch: GuestArch) -> [(String, String)] {
        let all: [(String, String)] = [
            ("__default__", "默认 (LSI 53C895A)"), ("lsi", "LSI 53C895A"), ("lsi53c810", "LSI 53C810"),
            ("megasas", "MegaRAID SAS 8708EM2"), ("virtio-scsi-pci", "VirtIO SCSI"),
            ("virtio-scsi-single", "VirtIO SCSI single"), ("pvscsi", "VMware PVSCSI"),
        ]
        if arch == .aarch64 { return all.filter { ["virtio-scsi-pci", "virtio-scsi-single"].contains($0.0) } }
        return all
    }

    public static func scsiControllerTitle(_ value: String) -> String {
        scsiControllers(for: .x86_64).first { $0.0 == (value.isEmpty ? "__default__" : value) }?.1 ?? value
    }

    public static func tpmVersions(for arch: GuestArch) -> [String] {
        arch == .aarch64 ? ["v2.0"] : ["v1.2", "v2.0"]
    }

    public static let cache: [(String, String)] = [
        ("__default__", "默认（无缓存）"), ("directsync", "Direct sync"), ("writethrough", "Write through"),
        ("writeback", "Write back"), ("unsafe", "Write back（不安全）"), ("none", "无缓存"),
    ]

    public static let aio: [(String, String)] = [
        ("__default__", "默认 (io_uring)"), ("io_uring", "io_uring"), ("native", "native"), ("threads", "threads"),
    ]

    public static let networkCards: [(String, String)] = [
        ("e1000", "Intel E1000"), ("e1000e", "Intel E1000E"), ("virtio", "VirtIO（半虚拟化）"),
        ("rtl8139", "Realtek RTL8139"), ("vmxnet3", "VMware vmxnet3"),
    ]

    public static func defaultCPUType(for arch: GuestArch) -> String {
        arch == .aarch64 ? "host" : "x86-64-v2-AES"
    }

    /// CPU models allowed with KVM on ARM.
    public static func isUsableOnARM(_ cputype: String) -> Bool {
        ["host", "max", "cortex-a53", "cortex-a57"].contains(cputype) || cputype.hasPrefix("custom-")
    }
}

public enum VMWizardStep: Int, Sendable, Hashable, CaseIterable, Identifiable {
    case general, os, system, disks, cpu, memory, network, confirm
    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .general: return "常规"
        case .os: return "操作系统"
        case .system: return "系统"
        case .disks: return "磁盘"
        case .cpu: return "CPU"
        case .memory: return "内存"
        case .network: return "网络"
        case .confirm: return "确认"
        }
    }
}

public enum CDMedia: String, Sendable, Hashable, CaseIterable, Identifiable {
    case iso, cdrom, none
    public var id: String { rawValue }
}

/// A storage selection for a disk: allocate on `storage`, or (storages with
/// `select_existing`) use `existingVolume`.
public struct DiskTarget: Sendable, Hashable {
    public var storage: String = ""
    public var existingVolume: String?
    /// nil: the format selector is disabled (≤ 1 format) and nothing is submitted.
    public var format: DiskFormat?
    public var selectExisting = false

    public init() {}

    /// Applies the WebUI's format rules for a newly chosen storage (§3.4.3).
    public mutating func select(_ storage: NodeStorage) {
        self.storage = storage.storage
        selectExisting = storage.selectExisting
        existingVolume = nil
        format = storage.offersFormatChoice ? storage.preferredFormat : nil
    }

    /// `<storage>:<size>` or the existing volume.
    func file(size: String) -> String {
        if selectExisting, let existingVolume { return existingVolume }
        return "\(storage):\(size)"
    }

    var isComplete: Bool {
        !storage.isEmpty && (!selectExisting || !(existingVolume ?? "").isEmpty)
    }
}

/// One disk of the 「磁盘」 step (`pveQemuHDInputPanel`), new or imported.
public struct VMDiskDraft: Sendable, Hashable, Identifiable {
    public var id = UUID()
    public var bus: DiskBus
    public var device: Int
    public var target = DiskTarget()
    /// GiB, 0.001 … 131072.
    public var size: Double = 32
    /// Import card: source storage and image (`import-from`).
    public var isImport = false
    public var importStorage: String = ""
    public var importFrom: String = ""
    public var cache = "__default__"
    public var discard = false
    public var iothread = false
    public var ssd = false
    public var readOnly = false
    public var backup = true
    public var skipReplication = false
    public var aio = "__default__"
    // Bandwidth (nil = unlimited).
    public var mbpsRd: Double?
    public var mbpsWr: Double?
    public var iopsRd: Int?
    public var iopsWr: Int?
    public var mbpsRdMax: Double?
    public var mbpsWrMax: Double?
    public var iopsRdMax: Int?
    public var iopsWrMax: Int?

    public init(bus: DiskBus, device: Int, isImport: Bool = false) {
        self.bus = bus
        self.device = device
        self.isImport = isImport
    }

    public var key: String { "\(bus.rawValue)\(device)" }

    /// IO thread is only available on VirtIO Block and SCSI.
    public var supportsIOThread: Bool { bus == .virtio || bus == .scsi }
    /// SSD emulation is not available on VirtIO Block.
    public var supportsSSD: Bool { bus != .virtio }
    public var supportsReadOnly: Bool { bus == .virtio || bus == .scsi }

    /// The WebUI recomputes IO thread whenever the bus or the SCSI controller changes.
    public static func defaultIOThread(bus: DiskBus, scsihw: String) -> Bool {
        bus == .virtio || (bus == .scsi && scsihw == "virtio-scsi-single")
    }

    /// Clears options the bus does not support (disabled fields are reset).
    public mutating func normalizeForBus(scsihw: String) {
        iothread = Self.defaultIOThread(bus: bus, scsihw: scsihw)
        if !supportsSSD { ssd = false }
        if !supportsReadOnly { readOnly = false }
    }

    /// `printQemuDrive` order.
    public var configString: String {
        var parts = [target.file(size: isImport ? "0" : WizardValidation.number(size))]
        if isImport && !importFrom.isEmpty { parts.append("import-from=\(importFrom)") }
        if let format = target.format, !target.selectExisting { parts.append("format=\(format.rawValue)") }
        if !backup { parts.append("backup=0") }
        if skipReplication { parts.append("replicate=no") }
        if discard { parts.append("discard=on") }
        if ssd && supportsSSD { parts.append("ssd=on") }
        if iothread && supportsIOThread { parts.append("iothread=on") }
        if readOnly && supportsReadOnly { parts.append("ro=on") }
        if cache != "__default__" { parts.append("cache=\(cache)") }
        if aio != "__default__" { parts.append("aio=\(aio)") }
        func add(_ key: String, _ value: Double?) { if let value { parts.append("\(key)=\(WizardValidation.number(value))") } }
        func add(_ key: String, _ value: Int?) { if let value { parts.append("\(key)=\(value)") } }
        add("mbps_rd", mbpsRd)
        add("mbps_rd_max", mbpsRdMax)
        add("mbps_wr", mbpsWr)
        add("mbps_wr_max", mbpsWrMax)
        add("iops_rd", iopsRd)
        add("iops_rd_max", iopsRdMax)
        add("iops_wr", iopsWr)
        add("iops_wr_max", iopsWrMax)
        return parts.joined(separator: ",")
    }
}

/// Three-state CPU flag (`-` off, `=` default, `+` on).
public enum CPUFlagState: String, Sendable, Hashable, CaseIterable {
    case off = "-", `default` = "=", on = "+"
}

/// Everything the Create VM wizard collects.
public struct VMWizard: Sendable, Hashable {
    // Node context.
    public var node: String = ""
    public var hostArch: GuestArch = .x86_64
    public var cgroupMode = 2
    public var isRootUser = false

    // General.
    public var vmid: Int?
    public var name = ""
    public var haManaged = false
    public var pool = ""
    public var onboot = false
    public var order = ""
    public var up = ""
    public var down = ""
    /// nil = 「默认（宿主架构）」.
    public var arch: GuestArch?
    public var tags: [String] = []

    // OS.
    public var media: CDMedia = .iso
    public var isoStorage = ""
    public var isoVolume = ""
    public var ostype = "l26"
    public var virtioDriversCD = false
    public var driversStorage = ""
    public var driversVolume = ""

    // System.
    public var vga = "__default__"
    public var machine = "__default__"
    public var bios = "__default__"
    public var addEFIDisk = true
    public var efi = DiskTarget()
    public var preEnrolledKeys = true
    public var scsihw = "virtio-scsi-single"
    public var agent = false
    public var addTPM = false
    public var tpm = DiskTarget()
    public var tpmVersion = "v2.0"
    public private(set) var systemDefaultsApplied = false

    // Disks.
    public var disks: [VMDiskDraft] = []

    // CPU.
    public var sockets = 1
    public var cores = 1
    /// Empty = default model.
    public var cputype = ""
    public var vcpus: Int?
    public var cpulimit: Double?
    public var affinity = ""
    public var cpuunits: Int?
    public var numa = false
    public var flags: [String: CPUFlagState] = [:]

    // Memory.
    public var memory = 2048
    public var balloon = 2048
    public var ballooning = true
    public var shares: Int?
    public var allowKSM = true
    public private(set) var memoryDefaultsApplied = false

    // Network.
    public var noNetwork = false
    public var bridge = ""
    public var vlanTag: Int?
    public var firewall = true
    public var model = "e1000"
    public var macAddress = ""
    public var disconnect = false
    public var mtu: Int?
    public var rate: Double?
    public var queues: Int?

    // Confirm.
    public var start = false

    public init() {}

    // MARK: Architecture

    public var effectiveArch: GuestArch { arch ?? hostArch }
    /// The installation CD drive: `ide2`, or `scsi2` on ARM.
    public var installDriveKey: String { effectiveArch == .aarch64 ? "scsi2" : "ide2" }
    public var osDefaults: QemuOSDefaults { QemuOSDefaults.get(ostype: ostype, arch: effectiveArch) }
    public var osBase: QemuOSBase { QemuOSType.base(of: ostype) }

    // MARK: Linkage

    /// `ostype` changed (OSPanel controller).
    public mutating func applyOSType(_ newValue: String) {
        ostype = newValue
        let defaults = osDefaults
        if osBase != .windows { virtioDriversCD = false }
        if disks.count == 1 { setBus(of: disks[0].id, to: virtioDriversCD ? .scsi : defaults.busType) }
        model = virtioDriversCD ? "virtio" : defaults.networkCard
        // OSDefaults has no cputype: the model goes back to the default.
        cputype = ""
        flags = [:]
        setSCSIController(defaults.scsihw.isEmpty ? "__default__" : defaults.scsihw)
    }

    /// 「为 VirtIO 驱动程序添加额外驱动器」.
    public mutating func setVirtIODriversCD(_ enabled: Bool) {
        virtioDriversCD = enabled
        if enabled {
            if let index = disks.firstIndex(where: { $0.key == "ide0" }) {
                disks[index].device = nextFreeDevice(on: disks[index].bus, excluding: disks[index].id) ?? disks[index].device
            }
            if disks.count == 1 { setBus(of: disks[0].id, to: .scsi) }
            model = "virtio"
        } else if disks.count == 1 {
            setBus(of: disks[0].id, to: osDefaults.busType)
        }
    }

    /// First display of the System step: machine, BIOS and TPM from the OS defaults, once.
    public mutating func applySystemDefaultsIfNeeded() {
        guard !systemDefaultsApplied else { return }
        systemDefaultsApplied = true
        let defaults = osDefaults
        machine = defaults.machine ?? "__default__"
        bios = defaults.bios ?? "__default__"
        if ostype == "win11" { addTPM = true }
        normalizeForArch()
    }

    /// First display of the Memory step: 2048 MiB, 4096 for Windows 11, once.
    public mutating func applyMemoryDefaultsIfNeeded() {
        guard !memoryDefaultsApplied else { return }
        memoryDefaultsApplied = true
        setMemory(ostype == "win11" ? 4096 : 2048)
    }

    /// Ballooning minimum follows the memory while they are equal and never exceeds it.
    public mutating func setMemory(_ newValue: Int) {
        if balloon == memory { balloon = newValue }
        memory = newValue
        if balloon > memory { balloon = memory }
    }

    public mutating func setSCSIController(_ value: String) {
        scsihw = value
        for index in disks.indices { disks[index].normalizeForBus(scsihw: value) }
    }

    /// Node or architecture changed: drop choices the architecture does not allow.
    public mutating func normalizeForArch() {
        let arch = effectiveArch
        if !QemuOSType.types(for: osBase, arch: arch).contains(where: { $0.value == ostype }) {
            ostype = arch == .aarch64 ? "l26" : ostype
        }
        if !QemuWizardOptions.machines(for: arch).contains(where: { $0.0 == machine }) { machine = "__default__" }
        if !QemuWizardOptions.bioses(for: arch).contains(where: { $0.0 == bios }) { bios = QemuWizardOptions.bioses(for: arch)[0].0 }
        if !QemuWizardOptions.scsiControllers(for: arch).contains(where: { $0.0 == scsihw }) { setSCSIController("virtio-scsi-single") }
        if !QemuWizardOptions.tpmVersions(for: arch).contains(tpmVersion) { tpmVersion = "v2.0" }
        let buses = DiskBus.available(for: arch)
        for index in disks.indices where !buses.contains(disks[index].bus) {
            let id = disks[index].id
            setBus(of: id, to: .scsi)
        }
    }

    // MARK: Disks

    /// Slots taken by CD drives and other disks.
    func occupiedKeys(excluding id: UUID? = nil) -> Set<String> {
        var keys: Set<String> = [installDriveKey]
        if virtioDriversCD { keys.insert("ide0") }
        for disk in disks where disk.id != id { keys.insert(disk.key) }
        return keys
    }

    public func nextFreeDevice(on bus: DiskBus, excluding id: UUID? = nil) -> Int? {
        let taken = occupiedKeys(excluding: id)
        return (0..<bus.maxDevices).first { !taken.contains("\(bus.rawValue)\($0)") }
    }

    /// `sortByPreviousUsage` + architecture filter + first free slot.
    public func nextFreeSlot() -> (DiskBus, Int)? {
        let priority = osDefaults.busPriority
        let used = Dictionary(grouping: disks, by: \.bus).mapValues(\.count)
        let order = DiskBus.allCases.sorted { lhs, rhs in
            let l = used[lhs] ?? 0, r = used[rhs] ?? 0
            if l != r { return l > r }
            return (priority[lhs] ?? 0) > (priority[rhs] ?? 0)
        }
        let allowed = DiskBus.available(for: effectiveArch)
        for bus in order where allowed.contains(bus) {
            if let device = nextFreeDevice(on: bus) { return (bus, device) }
        }
        return nil
    }

    /// 「添加」/「导入」: a new card on the next free slot with the first image storage.
    @discardableResult
    public mutating func addDisk(isImport: Bool = false, storage: NodeStorage?) -> UUID? {
        guard let (bus, device) = nextFreeSlot() else { return nil }
        var disk = VMDiskDraft(bus: bus, device: device, isImport: isImport)
        if let storage { disk.target.select(storage) }
        disk.normalizeForBus(scsihw: scsihw)
        disks.append(disk)
        return disk.id
    }

    public mutating func setBus(of id: UUID, to bus: DiskBus) {
        guard let index = disks.firstIndex(where: { $0.id == id }) else { return }
        disks[index].bus = bus
        disks[index].device = nextFreeDevice(on: bus, excluding: id) ?? 0
        disks[index].normalizeForBus(scsihw: scsihw)
    }

    /// Disks sorted like the WebUI list: bus name, then number.
    public var sortedDisks: [VMDiskDraft] {
        disks.sorted { ($0.bus.rawValue, $0.device) < ($1.bus.rawValue, $1.device) }
    }

    // MARK: Derived values

    public var totalCores: Int { sockets * cores }
    public var defaultCPUUnits: Int { cgroupMode == 1 ? 1024 : 100 }
    public var cpuUnitsRange: ClosedRange<Int> { cgroupMode == 1 ? 2...262_144 : 1...10_000 }

    /// `boot` only with the second CD drive (`calculateBootOrder`).
    public var bootOrder: String? {
        guard virtioDriversCD else { return nil }
        let order = (0..<4).map { "ide\($0)" } + (0..<31).map { "scsi\($0)" } + (0..<16).map { "virtio\($0)" } + (0..<6).map { "sata\($0)" }
        let keys = Set(disks.map(\.key))
        guard let disk = order.first(where: { keys.contains($0) && $0 != "ide0" && $0 != installDriveKey }) else { return nil }
        var result = "order=\(disk);ide2;ide0"
        if !noNetwork { result += ";net0" }
        return result
    }

    public var cpuString: String? {
        var type = cputype
        if type.isEmpty && effectiveArch == .x86_64 { type = QemuWizardOptions.defaultCPUType(for: .x86_64) }
        let flagText = flags.filter { $0.value != .default }.sorted { $0.key < $1.key }.map { $0.value.rawValue + $0.key }.joined(separator: ";")
        if type.isEmpty {
            return flagText.isEmpty ? nil : "kvm64,flags=\(flagText)"
        }
        return flagText.isEmpty ? type : "\(type),flags=\(flagText)"
    }

    public var net0: String? {
        guard !noNetwork else { return nil }
        var first = model
        let mac = macAddress.trimmingCharacters(in: .whitespaces)
        if !mac.isEmpty { first += "=\(mac)" }
        var parts = [first]
        if !bridge.isEmpty {
            parts.append("bridge=\(bridge)")
            if let vlanTag { parts.append("tag=\(vlanTag)") }
            if firewall { parts.append("firewall=1") }
        }
        if let rate { parts.append("rate=\(WizardValidation.number(rate))") }
        if let queues { parts.append("queues=\(queues)") }
        if disconnect { parts.append("link_down=1") }
        if let mtu, model == "virtio" { parts.append("mtu=\(mtu)") }
        return parts.joined(separator: ",")
    }

    var cdValue: String {
        switch media {
        case .iso: return "\(isoVolume),media=cdrom"
        case .cdrom: return "cdrom,media=cdrom"
        case .none: return "none,media=cdrom"
        }
    }

    var efiDiskValue: String? {
        guard bios == "ovmf" || (bios == "__default__" && effectiveArch == .aarch64), addEFIDisk else { return nil }
        var parts = [efi.file(size: "1"), "efitype=4m"]
        if preEnrolledKeys { parts.append("pre-enrolled-keys=1") }
        if let format = efi.format, !efi.selectExisting { parts.append("format=\(format.rawValue)") }
        return parts.joined(separator: ",")
    }

    var tpmValue: String? {
        guard addTPM else { return nil }
        var parts = [tpm.file(size: "1")]
        if let format = tpm.format, !tpm.selectExisting { parts.append("format=\(format.rawValue)") }
        parts.append("version=\(tpmVersion)")
        return parts.joined(separator: ",")
    }

    /// Whether the EFI disk options apply (OVMF chosen).
    public var usesOVMF: Bool { bios == "ovmf" || (bios == "__default__" && effectiveArch == .aarch64) }

    // MARK: Submission

    /// `POST /nodes/{node}/qemu`, exactly the parameters the WebUI submits.
    public func request() -> PVEAPI.PostNodesQemu {
        var request = PVEAPI.PostNodesQemu(node: node, vmid: vmid ?? 0)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if !trimmedName.isEmpty { request.name = trimmedName }
        if haManaged { request.haManaged = true }
        if !pool.isEmpty { request.pool = pool }
        if onboot { request.onboot = true }
        request.startup = WizardValidation.startup(order: order, up: up, down: down)
        if let arch {
            request.arch = PVEAPI.PostNodesQemu.Arch(rawValue: arch.rawValue)
            if arch != hostArch { request.kvm = false }
        }
        if !tags.isEmpty { request.tags = tags.joined(separator: ";") }
        // OS.
        if effectiveArch == .aarch64 { request.scsi[2] = cdValue } else { request.ide[2] = cdValue }
        if virtioDriversCD && osBase == .windows { request.ide[0] = "\(driversVolume),media=cdrom" }
        request.boot = bootOrder
        request.ostype = PVEAPI.PostNodesQemu.Ostype(rawValue: ostype)
        // System.
        if vga != "__default__" {
            request.vga = vga
            if vga.hasPrefix("serial"), let index = Int(vga.dropFirst("serial".count)) { request.serial[index] = "socket" }
        }
        if machine != "__default__" { request.machine = machine }
        if bios != "__default__" { request.bios = PVEAPI.PostNodesQemu.Bios(rawValue: bios) }
        request.efidisk0 = efiDiskValue
        if scsihw != "__default__" { request.scsihw = PVEAPI.PostNodesQemu.Scsihw(rawValue: scsihw) }
        if agent { request.agent = "1" }
        request.tpmstate0 = tpmValue
        // Disks.
        for disk in disks {
            switch disk.bus {
            case .ide: request.ide[disk.device] = disk.configString
            case .sata: request.sata[disk.device] = disk.configString
            case .virtio: request.virtio[disk.device] = disk.configString
            case .scsi: request.scsi[disk.device] = disk.configString
            }
        }
        // CPU.
        request.sockets = sockets
        request.cores = cores
        request.cpu = cpuString
        request.vcpus = vcpus
        if let cpulimit, cpulimit != 0 { request.cpulimit = cpulimit }
        let cpuset = affinity.trimmingCharacters(in: .whitespaces)
        if isRootUser && !cpuset.isEmpty { request.affinity = cpuset }
        if let cpuunits, cpuunits != defaultCPUUnits { request.cpuunits = cpuunits }
        request.numa = numa
        // Memory.
        request.memory = String(memory)
        if !ballooning {
            request.balloon = 0
        } else if balloon < memory {
            request.balloon = balloon
            request.shares = shares
        }
        if !allowKSM { request.allowKsm = false }
        // Network.
        if let net0 { request.net[0] = net0 }
        if start { request.start = true }
        return request
    }

    /// Confirm page: the submitted settings grouped by the step they come from.
    public func settings(for step: VMWizardStep) -> [WizardSetting] {
        let parameters = Dictionary(request().parameters, uniquingKeysWith: { _, last in last })
        let keys: [String]
        switch step {
        case .general:
            keys = ["vmid", "name", "ha-managed", "pool", "onboot", "startup", "arch", "kvm", "tags"]
        case .os:
            keys = [installDriveKey, "ide0", "ostype", "boot"]
        case .system:
            keys = ["vga"] + (0..<4).map { "serial\($0)" } + ["machine", "bios", "efidisk0", "scsihw", "agent", "tpmstate0"]
        case .disks:
            keys = sortedDisks.map(\.key)
        case .cpu:
            keys = ["sockets", "cores", "cpu", "vcpus", "cpulimit", "affinity", "cpuunits", "numa"]
        case .memory:
            keys = ["memory", "balloon", "shares", "allow-ksm"]
        case .network:
            keys = ["net0"]
        case .confirm:
            keys = ["start"]
        }
        var result: [WizardSetting] = []
        if step == .general { result.append(WizardSetting("nodename", node)) }
        for key in keys {
            if let value = parameters[key] { result.append(WizardSetting(key, value)) }
        }
        return result
    }

    // MARK: Validation

    /// Problems that keep the step from advancing (VMID availability is checked separately).
    public func problems(_ step: VMWizardStep) -> [WizardProblem] {
        var problems: [WizardProblem] = []
        switch step {
        case .general:
            if node.isEmpty { problems.append(WizardProblem("nodename", "请选择节点")) }
            if !VMID.isValid(vmid) { problems.append(WizardProblem("vmid", "VM ID 须为 100–999999999 之间的整数")) }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !WizardValidation.isDNSName(trimmed) { problems.append(WizardProblem("name", "该主机名无效")) }
            if tags.contains(where: { !WizardValidation.isTag($0) }) { problems.append(WizardProblem("tags", "标签包含无效字符。")) }
        case .os:
            if media == .iso {
                if isoStorage.isEmpty { problems.append(WizardProblem("cdimage", "请选择 ISO 所在的存储")) }
                if isoVolume.isEmpty { problems.append(WizardProblem("cdimage", "请选择 ISO 镜像")) }
            }
            if virtioDriversCD && osBase == .windows && driversVolume.isEmpty {
                problems.append(WizardProblem("ide0", "请选择 VirtIO 驱动的 ISO 镜像"))
            }
        case .system:
            if usesOVMF && addEFIDisk && !efi.isComplete { problems.append(WizardProblem("efidisk0", "请选择 EFI 存储")) }
            if addTPM && !tpm.isComplete { problems.append(WizardProblem("tpmstate0", "请选择 TPM 存储")) }
        case .disks:
            var seen: Set<String> = [installDriveKey]
            if virtioDriversCD { seen.insert("ide0") }
            for disk in sortedDisks {
                let field = "disk:\(disk.id.uuidString)"
                if !DiskBus.available(for: effectiveArch).contains(disk.bus) || !(0..<disk.bus.maxDevices).contains(disk.device) {
                    problems.append(WizardProblem(field, "\(disk.key)：总线/设备无效"))
                } else if seen.contains(disk.key) {
                    problems.append(WizardProblem(field, "\(disk.key)：该设备已被使用。"))
                }
                seen.insert(disk.key)
                if !disk.target.isComplete { problems.append(WizardProblem(field, "\(disk.key)：请选择存储")) }
                if disk.isImport {
                    if disk.importFrom.isEmpty { problems.append(WizardProblem(field, "\(disk.key)：请选择要导入的镜像")) }
                } else if !disk.target.selectExisting && !(0.001...131_072).contains(disk.size) {
                    problems.append(WizardProblem(field, "\(disk.key)：磁盘大小须在 0.001–131072 GiB 之间"))
                }
                func check(_ value: Double?, _ min: Double, _ label: String) {
                    if let value, value < min { problems.append(WizardProblem(field, "\(disk.key)：\(label)不能小于 \(WizardValidation.number(min))")) }
                }
                check(disk.mbpsRd, 1, "读取限制")
                check(disk.mbpsWr, 1, "写入限制")
                check(disk.mbpsRdMax, 1, "最大突发读取")
                check(disk.mbpsWrMax, 1, "最大突发写入")
                check(disk.iopsRd.map(Double.init), 10, "读取限制 (ops/s)")
                check(disk.iopsWr.map(Double.init), 10, "写入限制 (ops/s)")
                check(disk.iopsRdMax.map(Double.init), 10, "最大突发读取 (ops)")
                check(disk.iopsWrMax.map(Double.init), 10, "最大突发写入 (ops)")
            }
        case .cpu:
            if sockets < 1 { problems.append(WizardProblem("sockets", "CPU 插槽数至少为 1")) }
            if !(1...256).contains(cores) { problems.append(WizardProblem("cores", "核心数须在 1–256 之间")) }
            if let vcpus, !(1...max(1, totalCores)).contains(vcpus) { problems.append(WizardProblem("vcpus", "VCPUs 须在 1–\(totalCores) 之间")) }
            if let cpulimit, !(0...128).contains(cpulimit) { problems.append(WizardProblem("cpulimit", "CPU 限制须在 0–128 之间")) }
            let cpuset = affinity.trimmingCharacters(in: .whitespaces)
            if isRootUser && !cpuset.isEmpty && !WizardValidation.isCPUSet(cpuset) { problems.append(WizardProblem("affinity", "CPU 绑定格式无效，例如 0-3,8")) }
            if let cpuunits, !cpuUnitsRange.contains(cpuunits) { problems.append(WizardProblem("cpuunits", "CPU 权重须在 \(cpuUnitsRange.lowerBound)–\(cpuUnitsRange.upperBound) 之间")) }
            if effectiveArch == .aarch64 && arch == nil && !cputype.isEmpty && !QemuWizardOptions.isUsableOnARM(cputype) {
                problems.append(WizardProblem("cputype", "CPU 型号“\(cputype)”无法在 ARM 上配合 KVM 使用；请选择 host 或 max，或关闭 KVM。"))
            }
        case .memory:
            if !(1...4_178_944).contains(memory) { problems.append(WizardProblem("memory", "内存须在 1–4178944 MiB 之间")) }
            if ballooning && !(1...max(1, memory)).contains(balloon) { problems.append(WizardProblem("balloon", "最小内存须在 1–\(memory) MiB 之间")) }
            if let shares, !(0...50_000).contains(shares) { problems.append(WizardProblem("shares", "共享须在 0–50000 之间")) }
        case .network:
            guard !noNetwork else { break }
            if bridge.isEmpty { problems.append(WizardProblem("bridge", "请选择网桥")) }
            if let vlanTag, !(1...4094).contains(vlanTag) { problems.append(WizardProblem("tag", "VLAN 标签须在 1–4094 之间")) }
            let mac = macAddress.trimmingCharacters(in: .whitespaces)
            if !mac.isEmpty && !WizardValidation.isMAC(mac) { problems.append(WizardProblem("macaddr", "MAC 地址格式无效")) }
            if let mtu, model == "virtio", !(mtu == 1 || (576...65_520).contains(mtu)) {
                problems.append(WizardProblem("mtu", "MTU 须 ≥ 576，或填 1 以继承网桥的 MTU。"))
            }
            if let rate, !(0...10_240).contains(rate) { problems.append(WizardProblem("rate", "速率限制须在 0–10240 MB/s 之间")) }
            if let queues, !(1...64).contains(queues) { problems.append(WizardProblem("queues", "Multiqueue 须在 1–64 之间")) }
        case .confirm:
            break
        }
        return problems
    }
}
