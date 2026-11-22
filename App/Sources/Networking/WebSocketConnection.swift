import Foundation
import PVEKit

/// Thin wrapper around `URLSessionWebSocketTask` with the shared certificate policy.
/// Callbacks are delivered on the main actor.
final class WebSocketConnection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    enum Failure: Error {
        case certificate(CertificateTrustFailure)
        case http(status: Int)
        case transport(PVEError)
        case closed(code: Int, reason: String?)
    }

    var onOpen: (@MainActor () -> Void)?
    var onMessage: (@MainActor (Data) -> Void)?
    var onClose: (@MainActor (Failure?) -> Void)?

    private let evaluator: TrustEvaluator
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var finished = false
    private let lock = NSLock()

    init(evaluator: TrustEvaluator) {
        self.evaluator = evaluator
        super.init()
    }

    func connect(_ request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 64 * 1024 * 1024
        lock.withLock {
            self.session = session
            self.task = task
            finished = false
        }
        task.resume()
        receiveNext()
    }

    func send(_ data: Data) {
        guard let task = lock.withLock({ task }) else { return }
        task.send(.data(data)) { [weak self] error in
            guard let self, let error else { return }
            self.finish(self.map(error))
        }
    }

    func close() {
        let (task, session) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            finished = true
            defer {
                self.task = nil
                self.session = nil
            }
            return (self.task, self.session)
        }
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func receiveNext() {
        guard let task = lock.withLock({ task }) else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                let data: Data
                switch message {
                case .data(let bytes): data = bytes
                case .string(let text): data = Data(text.utf8)
                @unknown default: data = Data()
                }
                let handler = self.onMessage
                Task { @MainActor in handler?(data) }
                self.receiveNext()
            case .failure(let error):
                self.finish(self.map(error))
            }
        }
    }

    private func map(_ error: Error) -> Failure {
        if let failure = evaluator.takeLastFailure() {
            return .certificate(failure)
        }
        if let response = lock.withLock({ task?.response }) as? HTTPURLResponse, response.statusCode != 101 {
            return .http(status: response.statusCode)
        }
        if let urlError = error as? URLError {
            return .transport(PVEError.from(urlError: urlError))
        }
        if let task = lock.withLock({ task }), task.closeCode != .invalid {
            return .closed(code: task.closeCode.rawValue, reason: task.closeReason.flatMap { String(data: $0, encoding: .utf8) })
        }
        return .transport(.network(.connectionLost))
    }

    private func finish(_ failure: Failure?) {
        let alreadyFinished = lock.withLock { () -> Bool in
            defer { finished = true }
            return finished
        }
        guard !alreadyFinished else { return }
        let handler = onClose
        Task { @MainActor in handler?(failure) }
        close()
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let handler = onOpen
        Task { @MainActor in handler?() }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(.closed(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) }))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(map(error))
        } else {
            finish(.closed(code: 1000, reason: nil))
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrust.handle(challenge, evaluator: evaluator)
    }
}
