import Foundation

/// Validators of the create wizards, ported from widget-toolkit VTypes and PVE.Utils
/// (see docs/create-wizard-fields.md §1.4).
public enum WizardValidation {
    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// `DnsName`.
    public static func isDNSName(_ value: String) -> Bool {
        matches(value, #"^(?:(?:[a-zA-Z0-9](?:[a-zA-Z0-9\-]*[a-zA-Z0-9])?)\.)*(?:[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)$"#)
    }

    static let ipv4Octet = #"(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"#

    /// `IPAddress`.
    public static func isIPv4(_ value: String) -> Bool {
        matches(value, "^\(ipv4Octet)(?:\\.\(ipv4Octet)){3}$")
    }

    /// `IPCIDRAddress`: mask 8–32.
    public static func isIPv4CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isIPv4(String(parts[0])), parts[1].count <= 2, let mask = Int(parts[1]) else { return false }
        return (8...32).contains(mask)
    }

    /// `IP6Address` (RFC 4291, compressed forms and embedded IPv4).
    public static func isIPv6(_ value: String) -> Bool {
        guard !value.isEmpty, value.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return false }
        var address = value
        var groupsNeeded = 8
        // Embedded IPv4 at the end counts as two groups.
        if address.contains(".") {
            guard let lastColon = address.lastIndex(of: ":") else { return false }
            let v4 = String(address[address.index(after: lastColon)...])
            guard isIPv4(v4) else { return false }
            address = String(address[...lastColon]) + "0"
            groupsNeeded = 7
        }
        let doubleColons = address.components(separatedBy: "::").count - 1
        guard doubleColons <= 1 else { return false }
        if doubleColons == 1 {
            let halves = address.components(separatedBy: "::")
            let left = halves[0].isEmpty ? [] : halves[0].split(separator: ":", omittingEmptySubsequences: false)
            let right = halves[1].isEmpty ? [] : halves[1].split(separator: ":", omittingEmptySubsequences: false)
            let groups = left + right
            guard groups.count < groupsNeeded else { return false }
            return groups.allSatisfy { (1...4).contains($0.count) }
        }
        let groups = address.split(separator: ":", omittingEmptySubsequences: false)
        return groups.count == groupsNeeded && groups.allSatisfy { (1...4).contains($0.count) }
    }

    /// `IP6CIDRAddress`: prefix 8–128.
    public static func isIPv6CIDR(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isIPv6(String(parts[0])), parts[1].count <= 3, let prefix = Int(parts[1]) else { return false }
        return (8...128).contains(prefix)
    }

    /// `MacAddress`.
    public static func isMAC(_ value: String) -> Bool {
        matches(value, "^([a-fA-F0-9]{2}:){5}[a-fA-F0-9]{2}$")
    }

    /// `CpuSet`.
    public static func isCPUSet(_ value: String) -> Bool {
        matches(value, "^[0-9]+(?:-[0-9]+)?(?:,[0-9]+(?:-[0-9]+)?)*$")
    }

    /// `PVE.Utils.tagCharRegex`.
    public static func isTag(_ value: String) -> Bool {
        matches(value, "^[a-z0-9+_.-]+$") || matches(value.lowercased(), "^[a-z0-9+_.-]+$")
    }

    /// `IP64AddressWithSuffixList`: IPv4 or IPv6 entries separated by spaces, commas or
    /// semicolons; a `%iface` suffix only for `fe80:` addresses.
    public static func isAddressList(_ value: String) -> Bool {
        let entries = splitAddressList(value)
        guard !entries.isEmpty else { return false }
        return entries.allSatisfy { entry in
            let parts = entry.split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return false }
            let address = String(parts[0])
            if parts.count == 2 && !address.lowercased().hasPrefix("fe80:") { return false }
            return isIPv4(address) || isIPv6(address)
        }
    }

    public static func splitAddressList(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" }).map(String.init)
    }

    /// `PVE.Parser.parseSSHKey`: every non-empty line must be an OpenSSH public key.
    public static func isSSHKey(_ line: String) -> Bool {
        let pattern = #"^(?:((?:[^\s"]|"(?:\\.|[^"\\])*")+)\s+)?(\S+)\s+(\S+)(?:\s+(.*))?$"#
        let typePattern = #"^(?:(?:sk-)?(?:ssh-(?:dss|rsa|ed25519)|ecdsa-sha2-nistp\d+)(?:@(?:[a-z0-9_-]+\.)+[a-z]{2,})?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return false }
        func group(_ index: Int) -> String? {
            guard let r = Range(match.range(at: index), in: line) else { return nil }
            return String(line[r])
        }
        if let first = group(1), matches(first, typePattern) { return true }
        if let second = group(2), matches(second, typePattern) { return true }
        return false
    }

    public static func areSSHKeys(_ text: String) -> Bool {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.allSatisfy(isSSHKey)
    }

    /// `PVE.Parser.printStartup`.
    public static func startup(order: String, up: String, down: String) -> String? {
        var parts: [String] = []
        let o = order.trimmingCharacters(in: .whitespaces), u = up.trimmingCharacters(in: .whitespaces), d = down.trimmingCharacters(in: .whitespaces)
        if !o.isEmpty { parts.append("order=\(o)") }
        if !u.isEmpty { parts.append("up=\(u)") }
        if !d.isEmpty { parts.append("down=\(d)") }
        return parts.isEmpty ? nil : parts.joined(separator: ",")
    }

    /// Numbers as the WebUI submits them (no trailing `.0`).
    public static func number(_ value: Double) -> String {
        value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
    }
}

/// One step of a wizard with its problems; the UI blocks 「下一步」 while any exist.
public struct WizardProblem: Sendable, Hashable, Identifiable {
    public var id: String { field + ":" + message }
    /// Field identifier from docs/create-wizard-fields.md (e.g. `vmid`, `disk:scsi0`).
    public var field: String
    public var message: String

    public init(_ field: String, _ message: String) {
        self.field = field
        self.message = message
    }
}

/// A setting on the confirm page: the submitted key and value.
public struct WizardSetting: Sendable, Hashable, Identifiable {
    public var id: String { key }
    public var key: String
    public var value: String

    public init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }
}
