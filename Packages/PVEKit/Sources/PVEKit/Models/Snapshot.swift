import Foundation

/// Entry of `GET .../snapshot`. The list always contains a pseudo snapshot named `current`
/// ("You are here!") which is not a real snapshot.
public struct Snapshot: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String?
    public var parent: String?
    public var snaptime: Date?
    public var vmstate: Bool

    enum CodingKeys: String, CodingKey {
        case name, description, parent, snaptime, vmstate
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        let description = c.flexibleString(.description)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description?.isEmpty == true ? nil : description
        parent = c.flexibleString(.parent)
        snaptime = c.flexibleDouble(.snaptime).map { Date(timeIntervalSince1970: $0) }
        vmstate = c.flexibleBool(.vmstate) ?? false
    }

    public var isCurrent: Bool { name == "current" }

    /// Valid snapshot name: starts with a letter, then letters/digits/`-`/`_`, max 40 chars
    /// (pve-configid format).
    public static func isValidName(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLetter, name.count <= 40 else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            && name != "current"
    }
}

extension Array where Element == Snapshot {
    /// Real snapshots, newest first.
    public var realSnapshots: [Snapshot] {
        filter { !$0.isCurrent }.sorted { ($0.snaptime ?? .distantPast) > ($1.snaptime ?? .distantPast) }
    }
}
