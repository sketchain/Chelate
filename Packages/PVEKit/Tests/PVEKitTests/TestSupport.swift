import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PVEKit

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    /// Decodes the `data` member of a fixture like the client does.
    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try ResponseDecoding.decode(type, data: data(name), response: response(200))
    }

    static func response(_ status: Int, url: URL = URL(string: "https://pve.example:8006/api2/json")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    enum FixtureError: Error { case missing(String) }
}

/// Records requests and replies with queued responses, in order.
final class MockTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
    }

    private let lock = NSLock()
    private var replies: [Reply] = []
    private(set) var requests: [URLRequest] = []

    func enqueue(_ fixture: String, status: Int = 200) throws {
        let body = try Fixture.data(fixture)
        lock.withLock { replies.append(Reply(status: status, body: body)) }
    }

    func enqueue(status: Int, body: String) {
        lock.withLock { replies.append(Reply(status: status, body: Data(body.utf8))) }
    }

    var recorded: [URLRequest] { lock.withLock { requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply: Reply? = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let reply else {
            throw PVEError.network(.other("no reply queued for \(request.url?.absoluteString ?? "?")"))
        }
        return (reply.body, Fixture.response(reply.status, url: request.url!))
    }
}

extension URLRequest {
    /// Decoded form body as a dictionary.
    var formFields: [String: String] {
        guard let body = httpBody, let text = String(data: body, encoding: .utf8), !text.isEmpty else { return [:] }
        var fields: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let key = parts[0].removingPercentEncoding ?? parts[0]
            let value = parts.count > 1 ? (parts[1].removingPercentEncoding ?? parts[1]) : ""
            fields[key] = value
        }
        return fields
    }
}

/// Controllable clock for renewal tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Ticket timestamp used by the fixtures (`6921A3F0`).
let fixtureTicketDate = Date(timeIntervalSince1970: 0x6921A3F0)
