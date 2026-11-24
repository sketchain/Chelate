import Foundation

/// Where a PVE API lives: `https://<host>:<port>/api2/json`.
public struct ServerEndpoint: Sendable, Hashable, Codable {
    public static let defaultPort = 8006

    public var host: String
    public var port: Int

    public init(host: String, port: Int = ServerEndpoint.defaultPort) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
    }

    /// Host formatted for use in a URL authority (IPv6 literals get brackets).
    public var urlHost: String {
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.contains(":") {
            return "[\(bare)]"
        }
        return bare
    }

    public var isValid: Bool {
        guard !host.isEmpty, (1...65535).contains(port) else { return false }
        if host.contains("/") || host.contains(" ") || host.contains("?") || host.contains("#") { return false }
        return URL(string: "https://\(urlHost):\(port)/") != nil
    }

    /// `https://host:port/api2/json`
    public var apiBaseURL: URL {
        URL(string: "https://\(urlHost):\(port)/api2/json")!
    }

    /// `wss://host:port/api2/json`
    public var webSocketBaseURL: URL {
        URL(string: "wss://\(urlHost):\(port)/api2/json")!
    }

    /// Builds an API URL. `path` must start with `/` and have each segment already escaped
    /// (use `PathBuilder`).
    public func apiURL(path: String, query: [URLQueryItem] = []) -> URL {
        url(base: apiBaseURL, path: path, query: query)
    }

    public func webSocketURL(path: String, query: [URLQueryItem] = []) -> URL {
        url(base: webSocketBaseURL, path: path, query: query)
    }

    private func url(base: URL, path: String, query: [URLQueryItem]) -> URL {
        var string = base.absoluteString + path
        if !query.isEmpty {
            string += "?" + FormEncoding.encode(query.map { ($0.name, $0.value ?? "") })
        }
        return URL(string: string)!
    }
}

/// Builds escaped URL paths from raw segments, e.g. `["nodes", "pve1", "qemu", "100"]`.
public enum PathBuilder {
    public static func path(_ segments: String...) -> String {
        path(segments)
    }

    public static func path(_ segments: [String]) -> String {
        "/" + segments.map(escape).joined(separator: "/")
    }

    public static func escape(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: FormEncoding.unreserved) ?? segment
    }
}

/// `application/x-www-form-urlencoded` encoding with strict escaping (`+`, `=`, `&`, `:` ...).
public enum FormEncoding {
    /// RFC 3986 unreserved characters (ASCII only).
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    public static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    public static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }
}
