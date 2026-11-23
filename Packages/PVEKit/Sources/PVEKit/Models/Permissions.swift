import Foundation

/// PVE privilege names used by the app.
public enum Privilege: String, Sendable, Hashable, CaseIterable {
    case vmAudit = "VM.Audit"
    case vmPowerMgmt = "VM.PowerMgmt"
    case vmSnapshot = "VM.Snapshot"
    case vmSnapshotRollback = "VM.Snapshot.Rollback"
    case vmConsole = "VM.Console"
    case sysAudit = "Sys.Audit"
    case sysConsole = "Sys.Console"
    case datastoreAudit = "Datastore.Audit"
    case datastoreAllocateTemplate = "Datastore.AllocateTemplate"
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
