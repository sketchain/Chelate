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
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
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

        if method == "GET" {
            if match("version", parts) != nil {
                return ok(["version": "9.2.21", "release": "9.2", "repoid": "0123abcd"])
            }
            if match("cluster/resources", parts) != nil { return ok(DemoData.clusterResources()) }
            if match("access/permissions", parts) != nil { return ok(DemoData.permissions(path: query["path"])) }
            if match("cluster/tasks", parts) != nil || match("nodes/*/tasks", parts) != nil {
                return ok(DemoData.tasks(started: Array(started.values), vmid: query["vmid"].flatMap { Int($0) }))
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
            if let c = match("nodes/*/storage/*/content", parts) { return ok(DemoData.storageContent(c[1])) }
            if match("nodes/*/query-url-metadata", parts) != nil { return ok(DemoData.urlMetadata(query["url"] ?? "")) }
            if match("nodes/*/aplinfo", parts) != nil { return ok(DemoData.applianceTemplates()) }
            return notFound
        }

        if method == "POST" {
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
        return notFound
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
