import Foundation

// MARK: - Cluster status / HA

/// `GET /cluster/status`: the cluster entry (absent on a single node) and the nodes.
public struct ClusterStatus: Sendable, Hashable {
    public struct Node: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public var name: String
        public var online: Bool
        public var isLocal: Bool
        public var ip: String?
    }

    public var clusterName: String?
    /// nil without a cluster (a single node is always quorate).
    public var quorate: Bool?
    public var nodes: [Node]

    public init(clusterName: String? = nil, quorate: Bool? = nil, nodes: [Node] = []) {
        self.clusterName = clusterName
        self.quorate = quorate
        self.nodes = nodes
    }

    public init(_ value: JSONValue) {
        self.init()
        guard case .array(let items) = value else { return }
        for item in items {
            guard case .object(let object) = item else { continue }
            switch object["type"]?.stringValue {
            case "cluster":
                clusterName = object["name"]?.displayString
                quorate = object["quorate"].map { ($0.doubleValue ?? 0) != 0 }
            case "node":
                nodes.append(Node(
                    name: object["name"]?.displayString ?? "",
                    online: (object["online"]?.doubleValue ?? 0) != 0,
                    isLocal: (object["local"]?.doubleValue ?? 0) != 0,
                    ip: object["ip"]?.stringValue
                ))
            default:
                break
            }
        }
        nodes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var isCluster: Bool { clusterName != nil }
    public var onlineNodes: [String] { nodes.filter(\.online).map(\.name) }
}

/// An entry of `GET /cluster/ha/status/current` (quorum, master, lrm:<node>, service:<sid>).
public struct HAStatusEntry: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var type: String
    public var status: String
    public var node: String?
    public var sid: String?
    public var state: String?
    public var crmState: String?
    public var requestState: String?
    public var quorate: Bool?

    public init(id: String, type: String, status: String, node: String? = nil, sid: String? = nil, state: String? = nil, quorate: Bool? = nil) {
        self.id = id
        self.type = type
        self.status = status
        self.node = node
        self.sid = sid
        self.state = state
        self.quorate = quorate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.flexibleString(AnyCodingKey("id")) ?? ""
        type = c.flexibleString(AnyCodingKey("type")) ?? ""
        status = c.flexibleString(AnyCodingKey("status")) ?? ""
        node = c.flexibleString(AnyCodingKey("node"))
        sid = c.flexibleString(AnyCodingKey("sid"))
        state = c.flexibleString(AnyCodingKey("state"))
        crmState = c.flexibleString(AnyCodingKey("crm_state"))
        requestState = c.flexibleString(AnyCodingKey("request_state"))
        quorate = c.flexibleBool(AnyCodingKey("quorate"))
    }
}

/// A configured HA resource (`GET /cluster/ha/resources`) with its live state from the status.
public struct HAResource: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { sid }
    /// `vm:100`, `ct:200`.
    public var sid: String
    /// Requested state: started, stopped, enabled, disabled, ignored.
    public var requestedState: String?
    public var group: String?
    public var maxRestart: Int?
    public var maxRelocate: Int?
    public var comment: String?
    // From the status.
    public var node: String?
    public var currentState: String?
    public var crmState: String?

    public init(sid: String, requestedState: String?, node: String? = nil, currentState: String? = nil) {
        self.sid = sid
        self.requestedState = requestedState
        self.node = node
        self.currentState = currentState
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        sid = c.flexibleString(AnyCodingKey("sid")) ?? ""
        requestedState = c.flexibleString(AnyCodingKey("state"))
        group = c.flexibleString(AnyCodingKey("group"))
        maxRestart = c.flexibleInt(AnyCodingKey("max_restart"))
        maxRelocate = c.flexibleInt(AnyCodingKey("max_relocate"))
        comment = c.flexibleString(AnyCodingKey("comment"))
    }

    /// Joins the live state of `service:<sid>` entries.
    public static func merge(_ resources: [HAResource], status: [HAStatusEntry]) -> [HAResource] {
        resources.map { resource in
            var merged = resource
            if let entry = status.first(where: { $0.type == "service" && ($0.sid == resource.sid || $0.id == "service:\(resource.sid)") }) {
                merged.node = entry.node
                merged.currentState = entry.state
                merged.crmState = entry.crmState
            }
            return merged
        }
        .sorted { $0.sid.localizedStandardCompare($1.sid) == .orderedAscending }
    }

    public var vmid: Int? { sid.split(separator: ":").last.flatMap { Int($0) } }
}

// MARK: - Replication

/// A replication job (`GET /cluster/replication`) and its state on the source node
/// (`GET /nodes/{node}/replication`).
public struct ReplicationJob: Decodable, Sendable, Hashable, Identifiable {
    public var id: String
    public var guest: Int?
    public var target: String?
    public var schedule: String?
    public var rate: Double?
    public var comment: String?
    public var disabled: Bool
    public var source: String?
    // Status.
    public var lastSync: Date?
    public var nextSync: Date?
    /// Seconds.
    public var duration: Double?
    public var failCount: Int?
    public var error: String?
    public var state: String?

    public init(id: String, guest: Int?, target: String?) {
        self.id = id
        self.guest = guest
        self.target = target
        disabled = false
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = c.flexibleString(AnyCodingKey("id")) ?? ""
        guest = c.flexibleInt(AnyCodingKey("guest"))
        target = c.flexibleString(AnyCodingKey("target"))
        schedule = c.flexibleString(AnyCodingKey("schedule"))
        rate = c.flexibleDouble(AnyCodingKey("rate"))
        comment = c.flexibleString(AnyCodingKey("comment"))
        disabled = c.flexibleBool(AnyCodingKey("disable")) ?? false
        source = c.flexibleString(AnyCodingKey("source"))
        func date(_ key: String) -> Date? {
            c.flexibleDouble(AnyCodingKey(key)).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        }
        lastSync = date("last_sync")
        nextSync = date("next_sync")
        duration = c.flexibleDouble(AnyCodingKey("duration"))
        failCount = c.flexibleInt(AnyCodingKey("fail_count"))
        error = c.flexibleString(AnyCodingKey("error")).flatMap { $0.isEmpty ? nil : $0 }
        state = c.flexibleString(AnyCodingKey("state"))
    }

    /// Copies the status fields of `status` (same id).
    public func merging(status: ReplicationJob?) -> ReplicationJob {
        guard let status else { return self }
        var merged = self
        merged.lastSync = status.lastSync
        merged.nextSync = status.nextSync
        merged.duration = status.duration
        merged.failCount = status.failCount
        merged.error = status.error
        merged.state = status.state
        if merged.source == nil { merged.source = status.source }
        return merged
    }

    /// WebUI status column: 「OK」 or the error.
    public var isHealthy: Bool { error == nil && (failCount ?? 0) == 0 }
}

// MARK: - Firewall

/// The three firewall levels the app shows.
public enum FirewallScope: Sendable, Hashable {
    case datacenter
    case node(String)
    case guest(GuestRef)
}

/// A firewall rule (`GET …/firewall/rules`), read only.
public struct FirewallRule: Decodable, Sendable, Hashable, Identifiable {
    public var id: Int { pos }
    public var pos: Int
    /// `in`, `out`, `forward` or `group`.
    public var type: String
    /// ACCEPT, DROP, REJECT, or the security group name for `group`.
    public var action: String
    public var macro: String?
    public var source: String?
    public var dest: String?
    public var proto: String?
    public var dport: String?
    public var sport: String?
    public var iface: String?
    public var comment: String?
    public var enabled: Bool
    public var log: String?

    public init(pos: Int, type: String, action: String, enabled: Bool = true) {
        self.pos = pos
        self.type = type
        self.action = action
        self.enabled = enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        pos = c.flexibleInt(AnyCodingKey("pos")) ?? 0
        type = c.flexibleString(AnyCodingKey("type")) ?? ""
        action = c.flexibleString(AnyCodingKey("action")) ?? ""
        func text(_ key: String) -> String? {
            c.flexibleString(AnyCodingKey(key)).flatMap { $0.isEmpty ? nil : $0 }
        }
        macro = text("macro")
        source = text("source")
        dest = text("dest")
        proto = text("proto")
        dport = text("dport")
        sport = text("sport")
        iface = text("iface")
        comment = text("comment")
        enabled = c.flexibleBool(AnyCodingKey("enable")) ?? false
        log = text("log")
    }

    /// Protocol column: the macro wins when set, like the WebUI.
    public var protocolText: String? { macro ?? proto }
    /// Port column: `dport`, plus `sport` as `src` when present.
    public var portText: String? {
        switch (dport, sport) {
        case let (d?, s?): return "\(d) ← \(s)"
        case let (d?, nil): return d
        case let (nil, s?): return "← \(s)"
        default: return nil
        }
    }
}

/// Only `enable` of `…/firewall/options` (0/1; the datacenter level is an integer).
public struct FirewallOptions: Decodable, Sendable, Hashable {
    public var enabled: Bool
    public var policyIn: String?
    public var policyOut: String?

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        enabled = c.flexibleBool(AnyCodingKey("enable")) ?? false
        policyIn = c.flexibleString(AnyCodingKey("policy_in"))
        policyOut = c.flexibleString(AnyCodingKey("policy_out"))
    }
}

// MARK: - Notes

/// The `description` of a node or guest config, shown as Markdown.
public enum Notes {
    /// PVE stores comments as `#` lines in the config file; the API returns them as the
    /// description verbatim. Trailing whitespace is dropped.
    public static func normalized(_ text: String?) -> String {
        (text ?? "").replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
