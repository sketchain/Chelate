import Foundation

/// One line of the node's system log (`GET /nodes/{node}/journal`), as the WebUI's journal view
/// renders it.
public struct JournalEntry: Sendable, Hashable, Identifiable {
    public var id: Int
    /// Rendered line: `Nov 24 10:15:02 pve systemd[1]: Started …`.
    public var text: String
    public var date: Date?
    /// Syslog priority 0 (emerg) … 7 (debug); nil for legacy lines.
    public var priority: Int?
    public var isReboot: Bool

    public init(id: Int, text: String, date: Date? = nil, priority: Int? = nil, isReboot: Bool = false) {
        self.id = id
        self.text = text
        self.date = date
        self.priority = priority
        self.isReboot = isReboot
    }
}

/// A page of journal lines with the cursors to continue from.
public struct JournalPage: Sendable, Hashable {
    public var entries: [JournalEntry]
    /// Cursor of the oldest entry: pass as `endcursor` to load older lines.
    public var oldestCursor: String?
    /// Cursor of the newest entry: pass as `startcursor` to load newer lines.
    public var newestCursor: String?

    public init(entries: [JournalEntry], oldestCursor: String?, newestCursor: String?) {
        self.entries = entries
        self.oldestCursor = oldestCursor
        self.newestCursor = newestCursor
    }

    /// Parses the structured (`structured=1`, one object per entry) or legacy (strings, cursors
    /// first and last) response, like `Proxmox.panel.JournalView.processData`.
    public init(_ value: JSONValue, idOffset: Int = 0, timeZone: TimeZone = .current) {
        guard case .array(let items) = value else {
            self.init(entries: [], oldestCursor: nil, newestCursor: nil)
            return
        }
        var entries: [JournalEntry] = []
        var oldest: String?
        var newest: String?
        if case .object? = items.first {
            var host: String?
            for item in items {
                guard case .object(let object) = item else { continue }
                switch object["ty"]?.stringValue {
                case "cursor":
                    let cursor = object["c"]?.stringValue
                    if oldest == nil { oldest = cursor }
                    newest = cursor
                case "host":
                    host = object["h"]?.stringValue
                case "identifiers", "units":
                    continue
                case "reboot":
                    let date = object["t"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1_000_000) }
                    let stamp = date.map { JournalPage.format($0, timeZone: timeZone) + " " } ?? ""
                    entries.append(JournalEntry(id: idOffset + entries.count, text: stamp + "-- Reboot --", date: date, isReboot: true))
                default:
                    let date = object["t"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1_000_000) }
                    let pid = object["pid"].map { "[\($0.displayString)]" } ?? ""
                    let identifier = object["id"]?.displayString ?? ""
                    var prefix = date.map { JournalPage.format($0, timeZone: timeZone) } ?? ""
                    if let host { prefix += " " + host }
                    prefix += " " + identifier + pid + ": "
                    var message = object["msg"]?.displayString ?? ""
                    // Continuation lines line up under the message, like journalctl.
                    message = message.replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: prefix.count))
                    let priority = object["p"]?.doubleValue.map { Int($0) }
                    entries.append(JournalEntry(id: idOffset + entries.count, text: prefix + message, date: date, priority: priority ?? 6))
                }
            }
        } else {
            var lines = items.compactMap(\.stringValue)
            if !lines.isEmpty { oldest = lines.removeFirst() }
            if !lines.isEmpty { newest = lines.removeLast() }
            entries = lines.enumerated().map { JournalEntry(id: idOffset + $0.offset, text: $0.element) }
        }
        self.init(entries: entries, oldestCursor: oldest, newestCursor: newest)
    }

    static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// How a journal page is requested (mirrors the WebUI journal view's two modes).
public enum JournalQuery: Sendable, Hashable {
    /// The newest `count` lines.
    case latest(count: Int)
    /// `count` lines before `cursor` (scrolling up).
    case older(than: String, count: Int)
    /// Everything after `cursor` (polling for new lines).
    case newer(than: String)
    /// A time range in seconds since 1970 (`since` / `until`).
    case range(since: Date, until: Date)

    public func request(node: String) -> PVEAPI.GetNodesJournal {
        var request = PVEAPI.GetNodesJournal(node: node)
        switch self {
        case .latest(let count):
            request.lastentries = count
        case .older(let cursor, let count):
            request.lastentries = count
            request.endcursor = cursor
        case .newer(let cursor):
            request.startcursor = cursor
        case .range(let since, let until):
            request.since = Int(since.timeIntervalSince1970)
            request.until = Int(until.timeIntervalSince1970)
        }
        request.structured = true
        return request
    }
}

extension Array where Element == JournalEntry {
    /// Case-insensitive keyword filter (empty keyword keeps everything).
    public func matching(_ keyword: String) -> [JournalEntry] {
        let needle = keyword.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return self }
        return filter { $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
