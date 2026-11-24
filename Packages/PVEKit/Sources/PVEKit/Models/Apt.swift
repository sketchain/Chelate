import Foundation

/// An upgradable package of `GET /nodes/{node}/apt/update`.
public struct AptPackage: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { "\(name) \(version)" }
    public var name: String
    public var title: String?
    public var oldVersion: String?
    public var version: String
    public var origin: String?
    public var priority: String?
    public var section: String?
    public var description: String?
    public var arch: String?

    enum CodingKeys: String, CodingKey {
        case name = "Package"
        case title = "Title"
        case oldVersion = "OldVersion"
        case version = "Version"
        case origin = "Origin"
        case priority = "Priority"
        case section = "Section"
        case description = "Description"
        case arch = "Arch"
    }

    public init(name: String, oldVersion: String?, version: String, title: String? = nil, origin: String? = nil) {
        self.name = name
        self.oldVersion = oldVersion
        self.version = version
        self.title = title
        self.origin = origin
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.flexibleString(.name) ?? ""
        title = c.flexibleString(.title)
        oldVersion = c.flexibleString(.oldVersion).flatMap { $0.isEmpty ? nil : $0 }
        version = c.flexibleString(.version) ?? ""
        origin = c.flexibleString(.origin)
        priority = c.flexibleString(.priority)
        section = c.flexibleString(.section)
        description = c.flexibleString(.description)
        arch = c.flexibleString(.arch)
    }

    /// `1.2-3 → 1.2-4`, or only the new version for new packages.
    public var versionChange: String {
        if let oldVersion { return "\(oldVersion) → \(version)" }
        return version
    }
}

extension Array where Element == AptPackage {
    /// Sorted by origin (Proxmox first, like the WebUI groups) and then name.
    public var sortedForDisplay: [AptPackage] {
        sorted { lhs, rhs in
            let lp = lhs.origin == "Proxmox" ? 0 : 1
            let rp = rhs.origin == "Proxmox" ? 0 : 1
            if lp != rp { return lp < rp }
            return lhs.name < rhs.name
        }
    }
}
