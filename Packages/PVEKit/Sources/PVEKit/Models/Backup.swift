import Foundation

/// A backup of one guest on one storage: an entry of
/// `GET /nodes/{node}/storage/{storage}/content?content=backup&vmid=…`.
public struct BackupVolume: Sendable, Hashable, Identifiable {
    public var id: String { volid }
    public var storage: String
    public var volid: String
    public var vmid: Int?
    public var size: Double?
    public var ctime: Date?
    /// `vma.zst`, `tar.zst`, `pbs-vm`, `pbs-ct`, …
    public var format: String?
    public var notes: String?
    public var isProtected: Bool
    /// Proxmox Backup Server storage (`pbs-vm` / `pbs-ct` format).
    public var isPBS: Bool { format?.hasPrefix("pbs-") == true }

    public init(storage: String, item: StorageContentItem) {
        self.storage = storage
        volid = item.volid
        vmid = item.vmid ?? BackupVolume.vmid(fromVolid: item.volid)
        size = item.size
        ctime = item.ctime ?? BackupVolume.date(fromVolid: item.volid)
        format = item.format
        notes = item.notes
        isProtected = item.isProtected
    }

    /// The guest type the backup belongs to, from the format or the archive name
    /// (`vzdump-qemu-…`, `vzdump-lxc-…`, `pbs-vm`, `pbs-ct`, `vm/100/…`, `ct/100/…`).
    public var guestType: GuestType? {
        if let format {
            if format == "pbs-vm" || format.hasPrefix("vma") { return .qemu }
            if format == "pbs-ct" || format.hasPrefix("tar") { return .lxc }
        }
        let name = volid.lowercased()
        if name.contains("vzdump-qemu-") || name.contains(":backup/vm/") { return .qemu }
        if name.contains("vzdump-lxc-") || name.contains("vzdump-openvz-") || name.contains(":backup/ct/") { return .lxc }
        return nil
    }

    /// `local:backup/vzdump-qemu-100-2026_11_20-03_00_02.vma.zst` → 100;
    /// `pbs:backup/vm/100/2026-11-20T03:00:02Z` → 100.
    static func vmid(fromVolid volid: String) -> Int? {
        let patterns = [#"vzdump-(?:qemu|lxc|openvz)-(\d+)-"#, #"backup/(?:vm|ct)/(\d+)/"#]
        for pattern in patterns {
            if let range = volid.range(of: pattern, options: .regularExpression) {
                let digits = volid[range].split(whereSeparator: { !$0.isNumber }).first
                if let digits, let value = Int(digits) { return value }
            }
        }
        return nil
    }

    /// Time stamp in the archive name (local time of the node; treated as UTC when it has a `Z`).
    static func date(fromVolid volid: String) -> Date? {
        if let range = volid.range(of: #"\d{4}_\d{2}_\d{2}-\d{2}_\d{2}_\d{2}"#, options: .regularExpression) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy_MM_dd-HH_mm_ss"
            return formatter.date(from: String(volid[range]))
        }
        if let range = volid.range(of: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"#, options: .regularExpression) {
            return ISO8601DateFormatter().date(from: String(volid[range]))
        }
        return nil
    }
}

extension Array where Element == BackupVolume {
    /// Newest first.
    public var newestFirst: [BackupVolume] {
        sorted { ($0.ctime ?? .distantPast) > ($1.ctime ?? .distantPast) }
    }
}

/// Backup mode (`vzdump --mode`).
public enum BackupMode: String, Sendable, Hashable, CaseIterable, Identifiable {
    case snapshot, suspend, stop
    public var id: String { rawValue }

    /// Reads the mode a vzdump task used from its log: `INFO: backup mode: snapshot`.
    public static func fromTaskLog(_ lines: [String], vmid: Int? = nil) -> BackupMode? {
        var currentVMID: Int?
        for line in lines {
            // Multi-guest jobs log `INFO: Starting Backup of VM 100 (qemu)` before each guest.
            if let range = line.range(of: #"Starting Backup of VM (\d+)"#, options: .regularExpression) {
                currentVMID = line[range].split(separator: " ").last.flatMap { Int($0) }
            }
            if let range = line.range(of: "backup mode: ") {
                let word = line[range.upperBound...].prefix { $0.isLetter }
                guard let mode = BackupMode(rawValue: String(word)) else { continue }
                if vmid == nil || currentVMID == nil || currentVMID == vmid { return mode }
            }
        }
        return nil
    }
}

/// Compression of `vzdump` (`0` = none). PBS storages always use zstd.
public enum BackupCompression: String, Sendable, Hashable, CaseIterable, Identifiable {
    case none = "0"
    case lzo, gzip, zstd
    public var id: String { rawValue }
}

/// Notification setting of the WebUI's 「Backup now」 dialog.
public enum BackupNotificationMode: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// 「Use global settings」.
    case notificationSystem = "notification-system"
    /// 「Use sendmail (legacy)」: shows the e-mail field.
    case legacySendmail = "legacy-sendmail"
    case none
    public var id: String { rawValue }
}

/// PBS change detection mode for container backups (only shown for CTs on a PBS storage).
public enum PBSChangeDetectionMode: String, Sendable, Hashable, CaseIterable, Identifiable {
    case `default` = "__default__"
    case data, metadata
    public var id: String { rawValue }
}

/// Notes templates are single line: newline and backslash are escaped (`\n`, `\\`), exactly as
/// `PVE.Utils.escapeNotesTemplate` / `unEscapeNotesTemplate`.
public enum NotesTemplate {
    public static let variables = ["cluster", "guestname", "node", "uid", "vmid"]
    public static let defaultTemplate = "{{guestname}}"

    public static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            default: result.append(character)
            }
        }
        return result
    }

    public static func unescape(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "\\"?: result.append("\\")
            case "n"?: result.append("\n")
            case let other?: result.append("\\"); result.append(other)
            case nil: result.append("\\")
            }
        }
        return result
    }
}

/// 「Backup now」 for one guest, mirroring `PVE.window.Backup`: `POST /nodes/{node}/vzdump`.
public struct BackupRequest: Sendable, Hashable {
    public var vmid: Int
    public var storage: String
    public var mode: BackupMode = .snapshot
    public var compression: BackupCompression = .zstd
    public var notificationMode: BackupNotificationMode = .notificationSystem
    /// Only sent with `legacySendmail`.
    public var mailto: String = ""
    public var isProtected = false
    /// 「Prune」: prune older backups afterwards (offered when the storage has a retention).
    public var prune = false
    /// Sent unescaped here; escaped when building the request.
    public var notes: String = NotesTemplate.defaultTemplate
    public var changeDetection: PBSChangeDetectionMode = .default
    /// PBS target: compression is fixed (not sent as chosen).
    public var storageIsPBS = false
    public var guestType: GuestType = .qemu

    public init(vmid: Int, storage: String) {
        self.vmid = vmid
        self.storage = storage
    }

    public func request(node: String) -> PVEAPI.PostNodesVzdump {
        var request = PVEAPI.PostNodesVzdump(node: node)
        request.storage = storage
        request.vmid = String(vmid)
        request.mode = PVEAPI.PostNodesVzdump.Mode(rawValue: mode.rawValue)
        request.remove = prune
        let mail = mailto.trimmingCharacters(in: .whitespaces)
        if notificationMode == .legacySendmail && !mail.isEmpty {
            request.mailto = mail
        }
        request.notificationMode = PVEAPI.PostNodesVzdump.NotificationMode(rawValue: notificationMode.rawValue)
        request.compress = PVEAPI.PostNodesVzdump.Compress(rawValue: storageIsPBS ? BackupCompression.zstd.rawValue : compression.rawValue)
        if isProtected { request.protected = true }
        if storageIsPBS && guestType == .lxc && changeDetection != .default {
            request.pbsChangeDetectionMode = PVEAPI.PostNodesVzdump.PbsChangeDetectionMode(rawValue: changeDetection.rawValue)
        }
        if !notes.isEmpty {
            request.notesTemplate = NotesTemplate.escape(notes)
        }
        return request
    }
}

/// Retention of a backup storage (`prune-backups` property string of `vzdump/defaults`).
public struct BackupRetention: Sendable, Hashable {
    public var keepAll: Bool
    /// `keep-last`, `keep-hourly`, … in WebUI order, only the ones that are set.
    public var keeps: [(name: String, value: Int)]

    public static let order = ["keep-last", "keep-hourly", "keep-daily", "keep-weekly", "keep-monthly", "keep-yearly"]

    public init?(_ propertyString: String?) {
        guard let propertyString, !propertyString.isEmpty else { return nil }
        let values = PropertyString.parse(propertyString)
        keepAll = values["keep-all"] == "1"
        keeps = Self.order.compactMap { key in values[key].flatMap(Int.init).map { (key, $0) } }
    }

    /// Whether the WebUI shows the 「Prune」 checkbox.
    public var offersPrune: Bool { !keepAll }

    public static func == (lhs: BackupRetention, rhs: BackupRetention) -> Bool {
        lhs.keepAll == rhs.keepAll && lhs.keeps.map(\.name) == rhs.keeps.map(\.name) && lhs.keeps.map(\.value) == rhs.keeps.map(\.value)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(keepAll)
        for keep in keeps {
            hasher.combine(keep.name)
            hasher.combine(keep.value)
        }
    }
}

/// `key=value,key2=value2` property strings (PVE format strings). A leading value without `=`
/// is returned under `defaultKey`.
public enum PropertyString {
    public static func parse(_ string: String, defaultKey: String? = nil) -> [String: String] {
        var result: [String: String] = [:]
        for part in string.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if let eq = trimmed.firstIndex(of: "=") {
                result[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
            } else if let defaultKey, result[defaultKey] == nil {
                result[defaultKey] = trimmed
            }
        }
        return result
    }

    /// Builds `first,key=value,…` skipping nil values; keys keep the given order.
    public static func build(_ first: String?, _ pairs: [(String, String?)]) -> String {
        var parts: [String] = []
        if let first, !first.isEmpty { parts.append(first) }
        for (key, value) in pairs {
            if let value, !value.isEmpty { parts.append("\(key)=\(value)") }
        }
        return parts.joined(separator: ",")
    }
}

/// What a backup contains, from `GET /nodes/{node}/vzdump/extractconfig`: used as placeholders
/// of the restore dialog's override fields.
public struct BackupConfigSummary: Sendable, Hashable {
    public var name: String?
    public var memory: String?
    public var cores: String?
    public var sockets: String?
    /// The backup's unique ID (`meta: …,uid=…`), compared with the existing guest's.
    public var uid: String?
    /// Storages referenced by `#qmdump#map` lines; nil entries are raw devices.
    public var mappedStorages: [String?] = []

    public init(config: String) {
        for line in config.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, !value.contains(" ") || key == "#qmdump#map" else { continue }
            switch key {
            case "#qmdump#map":
                // `#qmdump#map:scsi0:drive-scsi0:local-zfs:raw:`
                let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                let storage = parts.count > 2 ? parts[2] : ""
                mappedStorages.append(storage.isEmpty ? nil : storage)
            case "name", "hostname": name = value
            case "memory": memory = value
            case "cores": cores = value
            case "sockets": sockets = value
            case "meta":
                uid = PropertyString.parse(value)["uid"]
            default: break
            }
        }
    }
}

/// 「Restore」 dialog (`PVE.window.Restore`): `POST /nodes/{node}/qemu` with `archive`, or
/// `POST /nodes/{node}/lxc` with `ostemplate` + `restore=1`.
public struct RestoreRequest: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        /// Overwrite the guest the backup belongs to (it must be stopped); sends `force=1`.
        case overwrite(vmid: Int)
        /// A new guest with this VMID.
        case new(vmid: Int)

        public var vmid: Int {
            switch self {
            case .overwrite(let vmid), .new(let vmid): return vmid
            }
        }

        public var isOverwrite: Bool {
            if case .overwrite = self { return true }
            return false
        }
    }

    /// CT privilege level: keep the backup's, or override.
    public enum PrivilegeLevel: String, Sendable, Hashable, CaseIterable, Identifiable {
        case keep, unprivileged, privileged
        public var id: String { rawValue }
    }

    public var volid: String
    public var type: GuestType
    public var target: Target
    /// nil: 「From backup configuration」 (VM) / required for CTs.
    public var storage: String?
    /// KiB/s; nil uses the storage's restore limit, 0 disables limits.
    public var bandwidthLimit: Int?
    public var unique = false
    public var start = false
    public var addToHA = false
    /// VM from PBS only; disables 「start」.
    public var liveRestore = false
    /// Only offered when overwriting.
    public var allowIdentityMismatch = false
    public var privilegeLevel: PrivilegeLevel = .keep
    // Override settings (empty = from backup).
    public var name: String = ""
    public var cores: Int?
    /// MiB.
    public var memory: Int?
    public var sockets: Int?

    public init(volid: String, type: GuestType, target: Target) {
        self.volid = volid
        self.type = type
        self.target = target
    }

    public func qemuRequest(node: String) -> PVEAPI.PostNodesQemu {
        var request = PVEAPI.PostNodesQemu(node: node, vmid: target.vmid)
        request.archive = volid
        request.force = target.isOverwrite
        if unique { request.unique = true }
        if start && !liveRestore { request.start = true }
        if addToHA { request.haManaged = true }
        if liveRestore { request.liveRestore = true }
        if target.isOverwrite && allowIdentityMismatch { request.allowIdentityMismatch = true }
        if let storage, !storage.isEmpty { request.storage = storage }
        request.bwlimit = bandwidthLimit
        request.cores = cores
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { request.name = trimmed }
        request.memory = memory.map(String.init)
        request.sockets = sockets
        return request
    }

    public func lxcRequest(node: String) -> PVEAPI.PostNodesLxc {
        var request = PVEAPI.PostNodesLxc(node: node, ostemplate: volid, vmid: target.vmid)
        request.restore = true
        request.force = target.isOverwrite
        if unique { request.unique = true }
        if start { request.start = true }
        if addToHA { request.haManaged = true }
        if target.isOverwrite && allowIdentityMismatch { request.allowIdentityMismatch = true }
        if let storage, !storage.isEmpty { request.storage = storage }
        request.bwlimit = bandwidthLimit.map(Double.init)
        request.cores = cores
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { request.hostname = trimmed }
        request.memory = memory
        switch privilegeLevel {
        case .keep: break
        case .unprivileged: request.unprivileged = true
        case .privileged: request.unprivileged = false
        }
        return request
    }
}
