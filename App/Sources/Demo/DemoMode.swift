import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PVEKit

/// Demo / screenshot mode, enabled with the launch argument `-ChelateDemo`. A fake server answers
/// every API call from fixture data in memory; no network request is made and nothing is written
/// to the Keychain or the server list.
enum DemoMode {
    static let launchArgument = "-ChelateDemo"
    /// Additionally pins a selection on the first chart (screenshot of the long-press popover).
    static let chartSelectionArgument = "-ChelateDemoChartSelection"

    static let isEnabled = ProcessInfo.processInfo.arguments.contains(launchArgument)
    static let pinsChartSelection = isEnabled && ProcessInfo.processInfo.arguments.contains(chartSelectionArgument)
}

/// Serves `/api2/json` from `DemoData`.
final class DemoTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startedTasks: [String: DemoData.StartedTask] = [:]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw PVEError.invalidEndpoint }
        // A little latency so loading states look natural.
        try await Task.sleep(for: .milliseconds(80))
        let prefix = "/api2/json"
        var path = url.path
        if path.hasPrefix(prefix) { path.removeFirst(prefix.count) }
        var items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // Form bodies of POST / PUT / DELETE are read like query parameters.
        if let body = request.httpBody, let text = String(data: body, encoding: .utf8), !text.isEmpty {
            var components = URLComponents()
            components.percentEncodedQuery = text.replacingOccurrences(of: "+", with: "%20")
            items += components.queryItems ?? []
        }
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let method = request.httpMethod ?? "GET"
        let (status, body) = route(method: method, path: path, query: query)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (data, response)
    }

    /// Matches `parts` against a pattern like `nodes/*/tasks/*/status`; returns the wildcards.
    private func match(_ pattern: String, _ parts: [String]) -> [String]? {
        let segments = pattern.split(separator: "/").map(String.init)
        guard segments.count == parts.count else { return nil }
        var captures: [String] = []
        for (segment, part) in zip(segments, parts) {
            if segment == "*" {
                captures.append(part)
            } else if segment != part {
                return nil
            }
        }
        return captures
    }

    private func route(method: String, path: String, query: [String: String]) -> (Int, Any) {
        let parts = path.split(separator: "/").map(String.init)
        func ok(_ data: Any) -> (Int, Any) { (200, ["data": data]) }
        let notFound: (Int, Any) = (404, ["data": NSNull(), "message": "Not implemented in demo mode"])
        let timeframe = RRDTimeframe(rawValue: query["timeframe"] ?? "") ?? .hour
        let started = lock.withLock { startedTasks }

        if method == "GET", let response = routeManagement(parts: parts, query: query, ok: ok) {
            return response
        }

        if method == "GET" {
            if match("version", parts) != nil {
                return ok(["version": "9.2.21", "release": "9.2", "repoid": "0123abcd"])
            }
            if match("cluster/resources", parts) != nil { return ok(DemoData.clusterResources()) }
            if match("access/permissions", parts) != nil { return ok(DemoData.permissions(path: query["path"])) }
            if match("cluster/tasks", parts) != nil || match("nodes/*/tasks", parts) != nil {
                return ok(DemoData.tasks(started: Array(started.values), vmid: query["vmid"].flatMap { Int($0) }, typefilter: query["typefilter"]))
            }
            if let c = match("nodes/*/tasks/*/status", parts) {
                return ok(DemoData.taskStatus(upid: c[1], started: started[c[1]]))
            }
            if let c = match("nodes/*/tasks/*/log", parts) {
                return ok(DemoData.taskLog(upid: c[1], started: started[c[1]]))
            }
            if let c = match("nodes/*/status", parts) { return ok(DemoData.nodeStatus(node: c[0])) }
            if match("nodes/*/rrddata", parts) != nil { return ok(DemoData.nodeRRD(timeframe: timeframe)) }
            if let c = match("nodes/*/*/*/rrddata", parts) {
                return ok(DemoData.guestRRD(type: c[1], vmid: Int(c[2]) ?? 0, timeframe: timeframe))
            }
            if let c = match("nodes/*/*/*/status/current", parts) {
                guard let status = DemoData.guestStatus(type: c[1], vmid: Int(c[2]) ?? 0) else { return notFound }
                return ok(status)
            }
            if let c = match("nodes/*/*/*/config", parts) {
                return ok(DemoData.guestConfig(type: c[1], vmid: Int(c[2]) ?? 0))
            }
            if match("nodes/*/*/*/snapshot", parts) != nil { return ok(DemoData.snapshots()) }
            if let c = match("nodes/*/storage/*/status", parts) {
                guard let status = DemoData.storageStatus(c[1]) else { return notFound }
                return ok(status)
            }
            if let c = match("nodes/*/storage/*/content", parts) {
                return ok(DemoData.storageContent(c[1], content: query["content"], vmid: query["vmid"].flatMap { Int($0) }))
            }
            if match("nodes/*/query-url-metadata", parts) != nil { return ok(DemoData.urlMetadata(query["url"] ?? "")) }
            if match("nodes/*/aplinfo", parts) != nil { return ok(DemoData.applianceTemplates()) }
            return notFound
        }

        if method == "POST" {
            if let c = match("nodes/*/vzdump", parts) {
                return ok(start(node: c[0], type: "vzdump", id: query["vmid"] ?? "100"))
            }
            if let c = match("nodes/*/qemu", parts) {
                return ok(start(node: c[0], type: query["archive"] != nil ? "qmrestore" : "qmcreate", id: query["vmid"] ?? DemoData.nextID()))
            }
            if let c = match("nodes/*/lxc", parts) {
                return ok(start(node: c[0], type: query["restore"] != nil ? "vzrestore" : "vzcreate", id: query["vmid"] ?? DemoData.nextID()))
            }
            if let c = match("nodes/*/*/*/clone", parts) {
                return ok(start(node: c[0], type: c[1] == "lxc" ? "vzclone" : "qmclone", id: c[2]))
            }
            if let c = match("nodes/*/*/*/migrate", parts) {
                return ok(start(node: c[0], type: c[1] == "lxc" ? "vzmigrate" : "qmigrate", id: c[2]))
            }
            if let c = match("nodes/*/*/*/template", parts) {
                if c[1] == "lxc" { return ok(NSNull()) }
                return ok(start(node: c[0], type: "qmtemplate", id: c[2]))
            }
            if let c = match("nodes/*/apt/update", parts) {
                return ok(start(node: c[0], type: "aptupdate", id: ""))
            }
            if let c = match("nodes/*/storage/*/download-url", parts) {
                return ok(start(node: c[0], type: "download", id: c[1]))
            }
            if let c = match("nodes/*/aplinfo", parts) {
                return ok(start(node: c[0], type: "download", id: "local"))
            }
            if let c = match("nodes/*/*/*/status/*", parts) {
                let prefix = c[1] == "lxc" ? "vz" : "qm"
                return ok(start(node: c[0], type: prefix + c[3], id: c[2]))
            }
            if let c = match("nodes/*/*/*/snapshot", parts) ?? match("nodes/*/*/*/snapshot/*/rollback", parts) {
                return ok(start(node: c[0], type: c[1] == "lxc" ? "vzsnapshot" : "qmsnapshot", id: c[2]))
            }
            return (501, ["data": NSNull(), "message": "Consoles are not available in demo mode"])
        }

        if method == "DELETE", let c = match("nodes/*/*/*/snapshot/*", parts) {
            return ok(start(node: c[0], type: c[1] == "lxc" ? "vzdelsnapshot" : "qmdelsnapshot", id: c[2]))
        }
        if method == "DELETE", let c = match("nodes/*/storage/*/content/*", parts) {
            return ok(start(node: c[0], type: "imgdel", id: c[2]))
        }
        if method == "DELETE", let c = match("nodes/*/*/*", parts), c[1] == "qemu" || c[1] == "lxc" {
            return ok(start(node: c[0], type: c[1] == "lxc" ? "vzdestroy" : "qmdestroy", id: c[2]))
        }
        if method == "PUT" {
            if let c = match("nodes/*/*/*/resize", parts) {
                return ok(start(node: c[0], type: "resize", id: c[2]))
            }
            // Config, notes and firewall changes are accepted and forgotten.
            return ok(NSNull())
        }
        return notFound
    }

    /// Read-only endpoints of backups, hardware, notes, system log, updates, HA, replication,
    /// firewall and the create wizards.
    private func routeManagement(parts: [String], query: [String: String], ok: (Any) -> (Int, Any)) -> (Int, Any)? {
        if match("nodes", parts) != nil { return ok(DemoData.nodes()) }
        if match("cluster/status", parts) != nil { return ok(DemoData.clusterStatus()) }
        if match("cluster/nextid", parts) != nil {
            if let vmid = query["vmid"].flatMap({ Int($0) }) {
                if DemoData.usedVMIDs.contains(vmid) {
                    return (400, ["data": NSNull(), "errors": ["vmid": "VM \(vmid) already exists"], "message": "Parameter verification failed."])
                }
                return ok(String(vmid))
            }
            return ok(DemoData.nextID())
        }
        if match("cluster/options", parts) != nil { return ok(DemoData.clusterOptions()) }
        if match("pools", parts) != nil { return ok(DemoData.pools()) }
        if match("cluster/ha/status/current", parts) != nil { return ok(DemoData.haStatus()) }
        if match("cluster/ha/resources", parts) != nil { return ok(DemoData.haResources()) }
        if match("cluster/replication", parts) != nil { return ok(DemoData.replicationJobs()) }
        if match("cluster/firewall/options", parts) != nil { return ok(DemoData.firewallOptions(scope: "cluster")) }
        if match("cluster/firewall/rules", parts) != nil { return ok(DemoData.firewallRules(scope: "cluster")) }
        if match("nodes/*/storage", parts) != nil { return ok(DemoData.nodeStorages(content: query["content"])) }
        if match("nodes/*/network", parts) != nil { return ok(DemoData.bridges()) }
        if match("nodes/*/capabilities/qemu/cpu", parts) != nil { return ok(DemoData.cpuModels()) }
        if match("nodes/*/capabilities/qemu/cpu-flags", parts) != nil { return ok(DemoData.cpuFlags()) }
        if match("nodes/*/vzdump/defaults", parts) != nil { return ok(DemoData.vzdumpDefaults(storage: query["storage"])) }
        if match("nodes/*/vzdump/extractconfig", parts) != nil { return ok(DemoData.extractConfig(volume: query["volume"] ?? "")) }
        if match("nodes/*/journal", parts) != nil { return ok(DemoData.journal(query: query)) }
        if match("nodes/*/apt/update", parts) != nil { return ok(DemoData.aptUpdates()) }
        if match("nodes/*/apt/changelog", parts) != nil { return ok(DemoData.changelog(name: query["name"] ?? "")) }
        if match("nodes/*/config", parts) != nil { return ok(["description": DemoData.nodeNotes, "digest": "0123"]) }
        if match("nodes/*/replication", parts) != nil { return ok(DemoData.replicationStatus()) }
        if match("nodes/*/firewall/options", parts) != nil { return ok(DemoData.firewallOptions(scope: "node")) }
        if match("nodes/*/firewall/rules", parts) != nil { return ok(DemoData.firewallRules(scope: "node")) }
        if let c = match("nodes/*/*/*/pending", parts) { return ok(DemoData.pending(type: c[1], vmid: Int(c[2]) ?? 0)) }
        if match("nodes/*/*/*/firewall/options", parts) != nil { return ok(DemoData.firewallOptions(scope: "guest")) }
        if match("nodes/*/*/*/firewall/rules", parts) != nil { return ok(DemoData.firewallRules(scope: "guest")) }
        if let c = match("nodes/*/*/*/migrate", parts) { return ok(DemoData.migrationCheck(vmid: Int(c[2]) ?? 0)) }
        if match("nodes/*/*/*/feature", parts) != nil { return ok(["hasFeature": 1, "nodes": [DemoData.node, DemoData.secondNode]]) }
        return nil
    }

    /// Records a fake task that runs for a few seconds and then succeeds.
    private func start(node: String, type: String, id: String) -> String {
        lock.withLock {
            let task = DemoData.StartedTask(node: node, type: type, objectID: id, start: Date(), pid: 0x1000 + startedTasks.count)
            startedTasks[task.upid] = task
            return task.upid
        }
    }
}

extension ServerConfig {
    /// The fixture server of demo mode (`-ChelateDemo`).
    static var demo: ServerConfig {
        var config = ServerConfig()
        config.id = DemoData.serverID
        config.name = "Homelab"
        config.host = "pve.demo.invalid"
        config.authMethod = .apiToken
        config.tokenUserID = "root@pam"
        config.tokenID = "demo"
        // A trusted self-signed certificate, so Settings shows a pinned fingerprint.
        config.pinnedFingerprint = CertificateFingerprint(bytes: (0..<32).map { UInt8(($0 * 37 + 11) % 256) })
        return config
    }
}
