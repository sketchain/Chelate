import Foundation

/// `UPID:<node>:<pid hex>:<pstart hex>:<starttime hex>:<type>:<id>:<user>:`
public struct UPID: Sendable, Hashable, Codable, CustomStringConvertible {
    public var raw: String
    public var node: String
    public var pid: Int
    public var startTime: Date
    public var type: String
    public var objectID: String
    public var user: String

    public init?(_ raw: String) {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        // Trailing ':' yields an empty last element.
        guard parts.count >= 8, parts[0] == "UPID" else { return nil }
        guard let pid = Int(parts[2], radix: 16), let start = UInt64(parts[4], radix: 16) else { return nil }
        self.raw = raw
        node = parts[1]
        self.pid = pid
        startTime = Date(timeIntervalSince1970: TimeInterval(start))
        type = parts[5]
        objectID = parts[6]
        // The user id never contains ':', but an API token id may contain '!'.
        user = parts[7]
    }

    public var description: String { raw }
}

/// `GET /nodes/{node}/tasks/{upid}/status`
public struct TaskStatus: Decodable, Sendable, Hashable {
    public var upid: String
    public var node: String
    public var status: String
    public var exitstatus: String?
    public var type: String?
    public var id: String?
    public var user: String?
    public var starttime: Date?

    enum CodingKeys: String, CodingKey {
        case upid, node, status, exitstatus, type, id, user, starttime
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        upid = c.flexibleString(.upid) ?? ""
        node = c.flexibleString(.node) ?? ""
        status = c.flexibleString(.status) ?? "unknown"
        exitstatus = c.flexibleString(.exitstatus)
        type = c.flexibleString(.type)
        id = c.flexibleString(.id)
        user = c.flexibleString(.user)
        starttime = c.flexibleDouble(.starttime).map { Date(timeIntervalSince1970: $0) }
    }

    public var isRunning: Bool { status == "running" }
    /// `OK`, `WARNINGS: n` count as success.
    public var succeeded: Bool {
        guard !isRunning, let exitstatus else { return false }
        return TaskOutcome.isSuccess(exitstatus)
    }
}

public enum TaskOutcome {
    public static func isSuccess(_ status: String) -> Bool {
        status == "OK" || status.hasPrefix("WARNINGS")
    }
}

/// Entry of `GET /cluster/tasks` or `GET /nodes/{node}/tasks`.
public struct TaskSummary: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { upid }
    public var upid: String
    public var node: String
    public var type: String
    public var objectID: String?
    public var user: String
    public var startTime: Date
    public var endTime: Date?
    /// Final status (`OK`, error text) or nil while running.
    public var status: String?

    enum CodingKeys: String, CodingKey {
        case upid, node, type, id, user, starttime, endtime, status
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        upid = try c.decode(String.self, forKey: .upid)
        let parsed = UPID(upid)
        node = c.flexibleString(.node) ?? parsed?.node ?? ""
        type = c.flexibleString(.type) ?? parsed?.type ?? ""
        objectID = c.flexibleString(.id) ?? parsed?.objectID
        user = c.flexibleString(.user) ?? parsed?.user ?? ""
        startTime = c.flexibleDouble(.starttime).map { Date(timeIntervalSince1970: $0) } ?? parsed?.startTime ?? .distantPast
        endTime = c.flexibleDouble(.endtime).map { Date(timeIntervalSince1970: $0) }
        let status = c.flexibleString(.status)
        self.status = (status == "running" || status?.isEmpty == true) ? nil : status
    }

    public var isRunning: Bool { status == nil && endTime == nil }
    public var succeeded: Bool { status.map(TaskOutcome.isSuccess) ?? false }
}

/// One line of `GET /nodes/{node}/tasks/{upid}/log`: `{"n": 1, "t": "text"}`.
public struct TaskLogLine: Decodable, Sendable, Hashable, Identifiable {
    public var id: Int { n }
    public var n: Int
    public var t: String

    enum CodingKeys: String, CodingKey { case n, t }

    public init(n: Int, t: String) {
        self.n = n
        self.t = t
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = c.flexibleInt(.n) ?? 0
        t = c.flexibleString(.t) ?? ""
    }
}
