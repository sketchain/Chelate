import Foundation

public enum RRDTimeframe: String, Sendable, Hashable, CaseIterable, Identifiable {
    case hour, day, week, month, year
    public var id: String { rawValue }
}

/// One row of `rrddata`. Values are kept in a dictionary because the column set differs between
/// nodes (`memused`/`memtotal`, `loadavg`, `iowait` ...) and guests (`mem`/`maxmem`,
/// `diskread`/`diskwrite` ...), and PVE 9 added more (`memhost`, `pressure*`, ...).
/// Gaps in the RRD are simply missing keys.
public struct RRDPoint: Decodable, Sendable, Hashable {
    public var time: Date
    public var values: [String: Double]

    public init(time: Date, values: [String: Double]) {
        self.time = time
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let seconds = c.flexibleDouble(AnyCodingKey("time")) else {
            throw DecodingError.keyNotFound(AnyCodingKey("time"), .init(codingPath: c.codingPath, debugDescription: "rrd row without time"))
        }
        time = Date(timeIntervalSince1970: seconds)
        var values: [String: Double] = [:]
        for key in c.allKeys where key.stringValue != "time" {
            if let value = c.flexibleDouble(key), value.isFinite {
                values[key.stringValue] = value
            }
        }
        self.values = values
    }

    public subscript(key: String) -> Double? { values[key] }
}

/// Chart series derived from RRD rows for both node and guest data.
public enum RRDMetric: String, Sendable, Hashable, CaseIterable {
    case cpu
    case memoryUsed
    case memoryTotal
    case netIn
    case netOut
    case diskRead
    case diskWrite
    case ioWait

    /// Column names, in order of preference (node vs guest naming).
    public var keys: [String] {
        switch self {
        case .cpu: return ["cpu"]
        case .memoryUsed: return ["memused", "mem"]
        case .memoryTotal: return ["memtotal", "maxmem"]
        case .netIn: return ["netin"]
        case .netOut: return ["netout"]
        case .diskRead: return ["diskread"]
        case .diskWrite: return ["diskwrite"]
        case .ioWait: return ["iowait"]
        }
    }

    public func value(in point: RRDPoint) -> Double? {
        for key in keys {
            if let value = point.values[key] { return value }
        }
        return nil
    }
}

public struct RRDSample: Sendable, Hashable, Identifiable {
    public var id: Date { time }
    public var time: Date
    public var value: Double
}

extension Array where Element == RRDPoint {
    public func samples(_ metric: RRDMetric) -> [RRDSample] {
        compactMap { point in
            metric.value(in: point).map { RRDSample(time: point.time, value: $0) }
        }
    }

    /// Whether any row contains this metric (to hide e.g. disk IO for nodes).
    public func contains(_ metric: RRDMetric) -> Bool {
        contains { metric.value(in: $0) != nil }
    }
}
