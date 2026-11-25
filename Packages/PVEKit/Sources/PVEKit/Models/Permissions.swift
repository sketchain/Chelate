import Foundation

/// PVE privilege names used by the app.
public enum Privilege: String, Sendable, Hashable, CaseIterable {
    case vmAudit = "VM.Audit"
    case vmPowerMgmt = "VM.PowerMgmt"
    case vmSnapshot = "VM.Snapshot"
    case vmSnapshotRollback = "VM.Snapshot.Rollback"
    case vmConsole = "VM.Console"
    case vmBackup = "VM.Backup"
    case vmAllocate = "VM.Allocate"
    case vmClone = "VM.Clone"
    case vmMigrate = "VM.Migrate"
    case vmConfigCPU = "VM.Config.CPU"
    case vmConfigMemory = "VM.Config.Memory"
    case vmConfigDisk = "VM.Config.Disk"
    case vmConfigOptions = "VM.Config.Options"
    case vmConfigNetwork = "VM.Config.Network"
    case vmConfigCDROM = "VM.Config.CDROM"
    case vmConfigHWType = "VM.Config.HWType"
    case vmConfigCloudinit = "VM.Config.Cloudinit"
    case sysAudit = "Sys.Audit"
    case sysModify = "Sys.Modify"
    case sysAccessNetwork = "Sys.AccessNetwork"
    case sysConsole = "Sys.Console"
    case sysSyslog = "Sys.Syslog"
    case datastoreAudit = "Datastore.Audit"
    case datastoreAllocateTemplate = "Datastore.AllocateTemplate"
    case datastoreAllocate = "Datastore.Allocate"
    case datastoreAllocateSpace = "Datastore.AllocateSpace"
    case poolAllocate = "Pool.Allocate"
    case sdnUse = "SDN.Use"
}

/// One privilege on one ACL path, e.g. `VM.Backup` on `/vms/100`.
public struct PermissionNeed: Sendable, Hashable {
    public var privilege: Privilege
    public var path: String

    public init(_ privilege: Privilege, on path: String) {
        self.privilege = privilege
        self.path = path
    }

    /// The ACL path of a guest (`/vms/{vmid}`).
    public static func vm(_ vmid: Int) -> String { "/vms/\(vmid)" }
    public static func node(_ node: String) -> String { "/nodes/\(node)" }
    public static func storage(_ storage: String) -> String { "/storage/\(storage)" }
}

extension Array where Element == PermissionNeed {
    /// The needs not granted by `granted`, in order and without duplicates.
    public func missing(_ granted: (Privilege, String) -> Bool) -> [PermissionNeed] {
        var seen: Set<PermissionNeed> = []
        return filter { need in
            guard !granted(need.privilege, need.path), !seen.contains(need) else { return false }
            seen.insert(need)
            return true
        }
    }
}

/// Result of `GET /access/permissions[?path=...]`: `{ "<path>": { "<priv>": 0|1 } }`.
/// With `path` set PVE computes the effective privileges for exactly that path (including pool
/// and propagated ACLs), so lookups below fall back to parent paths only for unqueried paths.
public struct PermissionMap: Decodable, Sendable, Hashable {
    public var paths: [String: Set<String>]

    public init(paths: [String: Set<String>]) {
        self.paths = paths
    }

    public init(from decoder: any Decoder) throws {
        let raw = try [String: [String: JSONValue]](from: decoder)
        var paths: [String: Set<String>] = [:]
        for (path, privs) in raw {
            // The value is the "propagate" flag; presence alone means the privilege is granted.
            paths[path] = Set(privs.keys)
        }
        self.paths = paths
    }

    /// Whether `privilege` is granted on `path`, using the most specific known ancestor.
    public func allows(_ privilege: Privilege, on path: String) -> Bool {
        var current = path
        while true {
            if let privs = paths[current] {
                return privs.contains(privilege.rawValue)
            }
            if current == "/" || current.isEmpty { return false }
            if let slash = current.lastIndex(of: "/") {
                current = slash == current.startIndex ? "/" : String(current[..<slash])
            } else {
                return false
            }
        }
    }

    public mutating func merge(_ other: PermissionMap) {
        for (path, privs) in other.paths {
            paths[path] = privs
        }
    }
}

/// Privilege requirement of `POST /nodes/{node}/storage/{storage}/download-url`, as defined in
/// pve-storage: `Datastore.AllocateTemplate` on `/storage/{storage}`, plus either `Sys.Audit`
/// and `Sys.Modify` on `/`, or `Sys.AccessNetwork` on `/nodes/{node}`.
public struct DownloadURLRequirement: Sendable, Hashable {
    public var node: String
    public var storage: String

    public init(node: String, storage: String) {
        self.node = node
        self.storage = storage
    }

    public var storagePath: String { "/storage/\(storage)" }
    public var nodePath: String { "/nodes/\(node)" }
    public static let rootPath = "/"

    /// ACL paths whose effective privileges are needed for the check.
    public var paths: [String] { [storagePath, Self.rootPath, nodePath] }

    /// What is missing, given a lookup `granted(privilege, path)`. Empty when allowed.
    public func missing(_ granted: (Privilege, String) -> Bool) -> [Missing] {
        var result: [Missing] = []
        if !granted(.datastoreAllocateTemplate, storagePath) {
            result.append(.privilege(.datastoreAllocateTemplate, path: storagePath))
        }
        let audit = granted(.sysAudit, Self.rootPath)
        let modify = granted(.sysModify, Self.rootPath)
        let network = granted(.sysAccessNetwork, nodePath)
        if !(audit && modify) && !network {
            var rootMissing: [Privilege] = []
            if !audit { rootMissing.append(.sysAudit) }
            if !modify { rootMissing.append(.sysModify) }
            result.append(.networkAccess(rootMissing: rootMissing, rootPath: Self.rootPath, nodePath: nodePath))
        }
        return result
    }

    public enum Missing: Sendable, Hashable {
        /// A single privilege on a path.
        case privilege(Privilege, path: String)
        /// Neither alternative is satisfied: `rootMissing` lists what is lacking on `/`
        /// (`Sys.AccessNetwork` on the node path would also do).
        case networkAccess(rootMissing: [Privilege], rootPath: String, nodePath: String)
    }
}
