import CoreTransferable
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import PVEKit
import UniformTypeIdentifiers

/// Rolling in-app log (network results, errors, auth events) for Settings › 导出日志.
///
/// Lines go to `Library/Caches/Logs/chelate.log`; at 256 KiB the file is rotated to
/// `chelate.1.log` (one generation kept, so at most about 512 KiB). Nothing secret is logged on
/// purpose, and the export runs everything through `LogRedactor` again.
final class AppLog: @unchecked Sendable {
    enum Category: String {
        case network = "net"
        case auth
        case error
        case app
        case widget
    }

    static let shared = AppLog()

    static let maxFileSize = 256 * 1024

    private let queue = DispatchQueue(label: "org.sketchain.chelate.log")
    private let directory: URL
    private let formatter: ISO8601DateFormatter

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.directory = caches.appendingPathComponent("Logs", isDirectory: true)
        }
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    var currentFile: URL { directory.appendingPathComponent("chelate.log") }
    var previousFile: URL { directory.appendingPathComponent("chelate.1.log") }

    func log(_ category: Category, _ message: @autoclosure () -> String) {
        guard !DemoMode.isEnabled else { return }
        let line = "\(formatter.string(from: Date())) [\(category.rawValue)] \(message())\n"
        queue.async { [self] in append(line) }
    }

    private func append(_ line: String) {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = (try? manager.attributesOfItem(atPath: currentFile.path)[.size] as? Int), size > Self.maxFileSize {
            try? manager.removeItem(at: previousFile)
            try? manager.moveItem(at: currentFile, to: previousFile)
        }
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: currentFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: currentFile, options: .atomic)
        }
    }

    /// Whole log (older generation first), redacted.
    func exportText() -> String {
        queue.sync {
            let parts = [previousFile, currentFile].compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            let header = "Chelate \(BuildInfo.summary)\nExported \(formatter.string(from: Date()))\n\n"
            return LogRedactor.redact(header + parts.joined())
        }
    }

    /// Writes the redacted export to a temporary `.txt` file.
    func exportFile() throws -> URL {
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = stampFormatter.string(from: Date())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Chelate-log-\(stamp).txt")
        try exportText().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: currentFile)
            try? FileManager.default.removeItem(at: previousFile)
        }
    }
}

/// The redacted log as a shareable text file (ShareLink).
struct LogExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { _ in
            SentTransferredFile(try AppLog.shared.exportFile())
        }
    }
}

/// Logs every API request: method, path (no query, no headers, no body), status and duration.
final class LoggingTransport: HTTPTransport {
    private let base: any HTTPTransport
    private let label: String

    init(_ base: any HTTPTransport, label: String) {
        self.base = base
        self.label = label
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let started = Date()
        let method = request.httpMethod ?? "GET"
        var path = request.url?.path ?? "?"
        if path.hasPrefix("/api2/json") { path.removeFirst("/api2/json".count) }
        do {
            let (data, response) = try await base.send(request)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            AppLog.shared.log(.network, "\(label) \(method) \(path) → \(response.statusCode) (\(ms) ms)")
            return (data, response)
        } catch {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if (error as? PVEError) == .cancelled || error is CancellationError {
                AppLog.shared.log(.network, "\(label) \(method) \(path) cancelled (\(ms) ms)")
            } else {
                AppLog.shared.log(.network, "\(label) \(method) \(path) failed (\(ms) ms): \(String(describing: error))")
            }
            throw error
        }
    }
}
