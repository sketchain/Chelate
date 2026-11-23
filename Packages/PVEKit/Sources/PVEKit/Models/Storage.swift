import Foundation

/// Storage content types (`content` option of a storage definition).
public enum StorageContentType: String, Sendable, Hashable, CaseIterable, Identifiable, Comparable {
    case iso
    case vztmpl
    case backup
    case images
    case rootdir
    case snippets
    case `import`

    public var id: String { rawValue }

    /// Display order of the groups in the content list.
    var order: Int { Self.allCases.firstIndex(of: self) ?? Int.max }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }

    /// Parses a comma separated content list (`"iso,vztmpl,backup"`), ignoring unknown values.
    public static func parseList(_ raw: String?) -> Set<StorageContentType> {
        guard let raw else { return [] }
        return Set(raw.split(separator: ",").compactMap { StorageContentType(rawValue: $0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Content types accepted by `download-url` that this app offers.
    public static let downloadable: [StorageContentType] = [.iso, .vztmpl]
}

/// Entry of `GET /nodes/{node}/storage/{storage}/content`.
public struct StorageContentItem: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { volid }
    public var volid: String
    /// Raw content type (`iso`, `vztmpl`, `backup`, `images`, `rootdir`, ...).
    public var content: String
    public var format: String?
    public var size: Double?
    public var used: Double?
    public var ctime: Date?
    public var vmid: Int?
    public var notes: String?
    public var isProtected: Bool

    enum CodingKeys: String, CodingKey {
        case volid, content, format, size, used, ctime, vmid, notes
        case isProtected = "protected"
    }

    public init(volid: String, content: String, format: String? = nil, size: Double? = nil, ctime: Date? = nil, vmid: Int? = nil) {
        self.volid = volid
        self.content = content
        self.format = format
        self.size = size
        self.used = nil
        self.ctime = ctime
        self.vmid = vmid
        self.notes = nil
        self.isProtected = false
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volid = try c.decode(String.self, forKey: .volid)
        content = c.flexibleString(.content) ?? ""
        format = c.flexibleString(.format)
        size = c.flexibleDouble(.size)
        used = c.flexibleDouble(.used)
        ctime = c.flexibleDouble(.ctime).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        vmid = c.flexibleInt(.vmid)
        let notes = c.flexibleString(.notes)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.notes = notes?.isEmpty == true ? nil : notes
        isProtected = c.flexibleBool(.isProtected) ?? false
    }

    public var contentType: StorageContentType? { StorageContentType(rawValue: content) }

    /// File / volume name without the storage id and type directory:
    /// `local:iso/debian.iso` → `debian.iso`, `local-zfs:vm-100-disk-0` → `vm-100-disk-0`.
    public var fileName: String {
        var name = volid
        if let colon = name.firstIndex(of: ":") {
            name = String(name[name.index(after: colon)...])
        }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        return name.isEmpty ? volid : name
    }
}

public struct StorageContentGroup: Sendable, Hashable, Identifiable {
    public var id: String { content }
    /// Raw content type of the group.
    public var content: String
    public var items: [StorageContentItem]
}

extension Array where Element == StorageContentItem {
    /// Groups by content type in a fixed order (ISO, templates, backups, disks ...); unknown types
    /// last. Items inside a group: newest first for backups, otherwise by name.
    public func groupedByContent() -> [StorageContentGroup] {
        let groups = Dictionary(grouping: self, by: \.content)
        return groups
            .map { key, items in
                let sorted = items.sorted { lhs, rhs in
                    if key == StorageContentType.backup.rawValue {
                        return (lhs.ctime ?? .distantPast) > (rhs.ctime ?? .distantPast)
                    }
                    return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
                }
                return StorageContentGroup(content: key, items: sorted)
            }
            .sorted { lhs, rhs in
                let l = StorageContentType(rawValue: lhs.content)?.order ?? Int.max
                let r = StorageContentType(rawValue: rhs.content)?.order ?? Int.max
                if l != r { return l < r }
                return lhs.content < rhs.content
            }
    }
}

/// `GET /nodes/{node}/storage/{storage}/status`
public struct StorageStatus: Decodable, Sendable, Hashable {
    public var type: String?
    public var content: Set<StorageContentType>
    public var total: Double?
    public var used: Double?
    public var avail: Double?
    public var active: Bool
    public var enabled: Bool
    public var shared: Bool

    enum CodingKeys: String, CodingKey { case type, content, total, used, avail, active, enabled, shared }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = c.flexibleString(.type)
        content = StorageContentType.parseList(c.flexibleString(.content))
        total = c.flexibleDouble(.total)
        used = c.flexibleDouble(.used)
        avail = c.flexibleDouble(.avail)
        active = c.flexibleBool(.active) ?? true
        enabled = c.flexibleBool(.enabled) ?? true
        shared = c.flexibleBool(.shared) ?? false
    }

    public var fraction: Double? {
        guard let used, let total, total > 0 else { return nil }
        return used / total
    }
}

/// `GET /nodes/{node}/query-url-metadata`
public struct URLMetadata: Decodable, Sendable, Hashable {
    public var filename: String?
    public var mimetype: String?
    public var size: Double?

    enum CodingKeys: String, CodingKey { case filename, mimetype, size }

    public init(filename: String?, mimetype: String?, size: Double?) {
        self.filename = filename
        self.mimetype = mimetype
        self.size = size
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = c.flexibleString(.filename)?.trimmingCharacters(in: .whitespacesAndNewlines)
        filename = name?.isEmpty == true ? nil : name
        mimetype = c.flexibleString(.mimetype)
        size = c.flexibleDouble(.size)
    }
}

/// `checksum-algorithm` of `download-url`.
public enum ChecksumAlgorithm: String, Sendable, Hashable, CaseIterable, Identifiable {
    case md5, sha1, sha224, sha256, sha384, sha512
    public var id: String { rawValue }
}

/// Parameters of `POST /nodes/{node}/storage/{storage}/download-url`.
public struct DownloadURLRequest: Sendable, Hashable {
    public var url: String
    public var content: StorageContentType
    public var filename: String
    public var checksum: String?
    public var checksumAlgorithm: ChecksumAlgorithm?
    public var verifyCertificates: Bool

    public init(url: String, content: StorageContentType, filename: String, checksum: String? = nil, checksumAlgorithm: ChecksumAlgorithm? = nil, verifyCertificates: Bool = true) {
        self.url = url
        self.content = content
        self.filename = filename
        self.checksum = checksum
        self.checksumAlgorithm = checksumAlgorithm
        self.verifyCertificates = verifyCertificates
    }

    var form: [(String, String)] {
        var form: [(String, String)] = [
            ("url", url.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("content", content.rawValue),
            ("filename", filename.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("verify-certificates", verifyCertificates ? "1" : "0"),
        ]
        if let checksum = checksum?.trimmingCharacters(in: .whitespacesAndNewlines), !checksum.isEmpty, let checksumAlgorithm {
            form.append(("checksum", checksum))
            form.append(("checksum-algorithm", checksumAlgorithm.rawValue))
        }
        return form
    }
}

/// Entry of `GET /nodes/{node}/aplinfo` (appliance / CT template index).
public struct ApplianceTemplate: Decodable, Sendable, Hashable, Identifiable {
    public var id: String { template }
    /// File name used for `POST aplinfo` (`template` parameter).
    public var template: String
    public var package: String?
    public var version: String?
    public var os: String?
    public var section: String?
    public var type: String?
    public var headline: String?
    public var description: String?
    public var architecture: String?
    public var infopage: String?
    public var location: String?

    enum CodingKeys: String, CodingKey {
        case template, package, version, os, section, type, headline, description, architecture, infopage, location
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decode(String.self, forKey: .template)
        package = c.flexibleString(.package)
        version = c.flexibleString(.version)
        os = c.flexibleString(.os)
        section = c.flexibleString(.section)
        type = c.flexibleString(.type)
        headline = c.flexibleString(.headline)
        description = c.flexibleString(.description)
        architecture = c.flexibleString(.architecture)
        infopage = c.flexibleString(.infopage)
        location = c.flexibleString(.location)
    }

    /// Case-insensitive match on template, package, headline and OS.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return [template, package, headline, os, description].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

extension Array where Element == ApplianceTemplate {
    /// Sections present in the index (`system`, `turnkeylinux`, `mail` ...), `system` first.
    public var sections: [String] {
        let all = Set(compactMap(\.section))
        return all.sorted { lhs, rhs in
            if lhs == "system" { return rhs != "system" }
            if rhs == "system" { return false }
            return lhs < rhs
        }
    }
}
