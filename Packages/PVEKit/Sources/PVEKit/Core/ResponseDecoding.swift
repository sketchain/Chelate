import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `{"data": ...}` envelope used by `/api2/json`.
struct DataEnvelope<T: Decodable>: Decodable {
    let data: T
}

/// Error body: `{"data": null, "message": "...", "errors": {"param": "reason"}}`.
struct ErrorEnvelope: Decodable {
    let message: String?
    let errors: [String: String]?
}

enum ResponseDecoding {
    static func decoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Validates the HTTP status and decodes the `data` member.
    static func decode<T: Decodable>(_ type: T.Type, data: Data, response: HTTPURLResponse) throws -> T {
        try check(data: data, response: response)
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try decoder().decode(DataEnvelope<T>.self, from: data).data
        } catch let error as DecodingError {
            throw PVEError.decoding(describe(error))
        }
    }

    static func check(data: Data, response: HTTPURLResponse) throws {
        let status = response.statusCode
        guard !(200..<300).contains(status) else { return }
        let message = errorMessage(data: data)
        switch status {
        case 401: throw PVEError.unauthorized(message: message)
        case 403: throw PVEError.forbidden(message: message)
        case 404: throw PVEError.notFound(message: message)
        default: throw PVEError.http(status: status, message: message)
        }
    }

    static func errorMessage(data: Data) -> String? {
        guard let envelope = try? decoder().decode(ErrorEnvelope.self, from: data) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) || (text?.hasPrefix("<") ?? false) ? nil : text
        }
        var parts: [String] = []
        if let message = envelope.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            parts.append(message)
        }
        if let errors = envelope.errors, !errors.isEmpty {
            parts.append(errors.keys.sorted().map { "\($0): \(errors[$0]!.trimmingCharacters(in: .whitespacesAndNewlines))" }.joined(separator: "; "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "missing key '\(key.stringValue)' at \(path(context))"
        case .typeMismatch(let type, let context):
            return "type mismatch (\(type)) at \(path(context))"
        case .valueNotFound(let type, let context):
            return "missing value (\(type)) at \(path(context))"
        case .dataCorrupted(let context):
            return "corrupted data at \(path(context)): \(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    private static func path(_ context: DecodingError.Context) -> String {
        context.codingPath.map(\.stringValue).joined(separator: ".")
    }
}

/// For endpoints whose result we ignore (`null`).
public struct EmptyResponse: Decodable, Sendable, Hashable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}

enum RequestFactory {
    static func make(
        endpoint: ServerEndpoint,
        method: HTTPMethod,
        path: String,
        query: [URLQueryItem],
        form: [(String, String)]?,
        headers: [String: String]
    ) -> URLRequest {
        var request = URLRequest(url: endpoint.apiURL(path: path, query: query))
        request.httpMethod = method.rawValue
        request.timeoutInterval = 30
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let form {
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(FormEncoding.encode(form).utf8)
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"

    var isWrite: Bool { self != .get }
}
