import Foundation
import Observation
import PVEKit
import SwiftTerm
import UIKit

/// One termproxy console (node shell or LXC console) rendered natively by SwiftTerm.
@MainActor
@Observable
final class TerminalSession {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        /// Ended or interrupted; `message` explains why (nil = user/background).
        case disconnected(message: String?)
    }

    private(set) var phase: Phase = .idle
    let connection: ServerConnection
    let target: ConsoleTarget

    @ObservationIgnored weak var terminalView: TerminalView?
    @ObservationIgnored private var socket: WebSocketConnection?
    @ObservationIgnored private var proto: TermProxyProtocol?
    @ObservationIgnored private var pingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var size: (cols: Int, rows: Int)?
    /// Set when the app went to the background while connected, to reconnect on return.
    @ObservationIgnored private(set) var shouldReconnect = false

    init(connection: ServerConnection, target: ConsoleTarget) {
        self.connection = connection
        self.target = target
    }

    var advisory: ConsoleAdvisory {
        ConsoleAdvisory.evaluate(target: target, authID: connection.client.auth.authID, usesToken: connection.usesAPIToken)
    }

    func start() async {
        teardown()
        generation += 1
        let generation = generation
        phase = .connecting
        shouldReconnect = false
        do {
            let ticket = try await connection.client.termProxy(target)
            let request = try await connection.client.termProxyWebSocketRequest(target, ticket: ticket)
            guard generation == self.generation else { return }

            var proto = TermProxyProtocol(user: ticket.user, ticket: ticket.ticket)
            if let size { _ = proto.encodeResize(cols: size.cols, rows: size.rows) }
            self.proto = proto

            let socket = WebSocketConnection(evaluator: connection.trust)
            socket.onOpen = { [weak self] in
                guard let self, generation == self.generation, let auth = self.proto?.didOpen() else { return }
                self.socket?.send(auth)
            }
            socket.onMessage = { [weak self] data in
                guard let self, generation == self.generation else { return }
                self.handle(data)
            }
            socket.onClose = { [weak self] failure in
                guard let self, generation == self.generation else { return }
                self.handleClose(failure)
            }
            self.socket = socket
            socket.connect(request)
        } catch {
            guard generation == self.generation else { return }
            connection.absorb(error)
            phase = .disconnected(message: startFailureMessage(error))
        }
    }

    /// App moved to the background: drop the socket, reconnect when active again.
    func suspend() {
        guard phase == .connected || phase == .connecting else { return }
        shouldReconnect = true
        teardown()
        phase = .disconnected(message: nil)
    }

    func stop() {
        shouldReconnect = false
        teardown()
        phase = .idle
    }

    private func teardown() {
        generation += 1
        pingTask?.cancel()
        pingTask = nil
        socket?.close()
        socket = nil
        proto = nil
    }

    // MARK: - Terminal I/O

    func sendInput(_ bytes: ArraySlice<UInt8>) {
        guard let frame = proto?.encodeInput(bytes) else { return }
        socket?.send(frame)
    }

    func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        guard proto != nil, let frame = proto?.encodeResize(cols: cols, rows: rows) else { return }
        socket?.send(frame)
    }

    private func handle(_ data: Data) {
        guard proto != nil, let event = proto?.receive(data) else { return }
        switch event {
        case .output(let output):
            terminalView?.feed(byteArray: ArraySlice(output))
        case .authenticated(let output, let send):
            phase = .connected
            if !output.isEmpty {
                terminalView?.feed(byteArray: ArraySlice(output))
            }
            send.forEach { socket?.send($0) }
            if let size, let frame = proto?.encodeResize(cols: size.cols, rows: size.rows) {
                socket?.send(frame)
            }
            startPing()
        case .authenticationFailed:
            teardown()
            phase = .disconnected(message: authFailureMessage)
        case .none:
            break
        }
    }

    private func startPing() {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(TermProxyCodec.pingInterval))
                guard let self, !Task.isCancelled, let frame = self.proto?.encodePing() else { return }
                self.socket?.send(frame)
            }
        }
    }

    private func handleClose(_ failure: WebSocketConnection.Failure?) {
        let wasConnected = phase == .connected
        teardown()
        switch failure {
        case .certificate(let issue)?:
            connection.certificateIssue = issue
            phase = .disconnected(message: ErrorText.message(for: PVEError.certificate(issue)))
        case .http(let status)?:
            phase = .disconnected(message: handshakeFailureMessage(status: status))
        case .transport(let error)?:
            phase = .disconnected(message: ErrorText.message(for: error))
        case .closed?, nil:
            phase = .disconnected(message: wasConnected ? String(localized: "会话已结束。") : authFailureMessage)
        }
    }

    // MARK: - Messages

    private var privilegeName: String {
        target.requiredPrivilege.rawValue
    }

    private var tokenHint: String {
        connection.usesAPIToken
            ? String(localized: "\n\n当前使用 API Token 认证。如果 Token 启用了“权限分离”，需要单独给 Token 授予 \(privilegeName) 权限；也可以改用账号密码登录后再试。")
            : ""
    }

    private var authFailureMessage: String {
        String(localized: "控制台认证失败：服务器拒绝了终端票据。") + tokenHint
    }

    private func startFailureMessage(_ error: Error) -> String {
        if case PVEError.forbidden? = error as? PVEError {
            return String(localized: "没有权限打开控制台（需要 \(privilegeName)）。") + tokenHint
        }
        return ErrorText.message(for: error)
    }

    private func handshakeFailureMessage(status: Int) -> String {
        switch status {
        case 401:
            return String(localized: "WebSocket 认证失败（HTTP 401）。") + tokenHint
        case 403:
            return String(localized: "没有权限连接控制台（HTTP 403，需要 \(privilegeName)）。") + tokenHint
        default:
            return String(localized: "无法建立控制台连接（HTTP \(status)）。")
        }
    }
}
