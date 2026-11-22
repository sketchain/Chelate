import Foundation
import Observation
import PVEKit
import UniformTypeIdentifiers
import WebKit

/// Graphical console for a qemu guest: `vncproxy` (websocket=1) → native `vncwebsocket` →
/// bridged into noVNC inside a WKWebView. The VNC password is the vncproxy ticket.
@MainActor
@Observable
final class VNCSession: NSObject {
    enum Phase: Equatable {
        case loadingPage
        case connecting
        case connected
        case disconnected(message: String?)
    }

    private(set) var phase: Phase = .loadingPage
    private(set) var desktopName: String?
    let connection: ServerConnection
    let guest: GuestRef

    @ObservationIgnored private(set) var webView: WKWebView!
    @ObservationIgnored private var socket: WebSocketConnection?
    @ObservationIgnored private var pageReady = false
    @ObservationIgnored private var wantsConnect = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inbound: [Data] = []
    @ObservationIgnored private var flushScheduled = false
    @ObservationIgnored private(set) var shouldReconnect = false
    @ObservationIgnored private var navigationDelegate: VNCNavigationDelegate?

    static let scheme = "chelate-vnc"

    init(connection: ServerConnection, guest: GuestRef) {
        self.connection = connection
        self.guest = guest
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: Self.scheme)
        configuration.userContentController.add(WeakScriptMessageHandler(self), name: "chelate")
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        let navigationDelegate = VNCNavigationDelegate(evaluator: connection.trust)
        webView.navigationDelegate = navigationDelegate
        #if DEBUG
        webView.isInspectable = true
        #endif
        self.navigationDelegate = navigationDelegate
        self.webView = webView
        webView.load(URLRequest(url: URL(string: "\(Self.scheme)://app/index.html")!))
    }

    func start() async {
        teardown()
        generation += 1
        let generation = generation
        shouldReconnect = false
        phase = .connecting
        wantsConnect = true
        do {
            let ticket = try await connection.client.vncProxy(guest)
            let request = try await connection.client.vncWebSocketRequest(guest, ticket: ticket)
            guard generation == self.generation else { return }
            let socket = WebSocketConnection(evaluator: connection.trust)
            socket.onOpen = { [weak self] in
                guard let self, generation == self.generation else { return }
                self.openRFB(password: ticket.password ?? ticket.ticket, generation: generation)
            }
            socket.onMessage = { [weak self] data in
                guard let self, generation == self.generation else { return }
                self.enqueue(data)
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

    func suspend() {
        guard phase == .connected || phase == .connecting else { return }
        shouldReconnect = true
        teardown()
        phase = .disconnected(message: nil)
    }

    func stop() {
        shouldReconnect = false
        teardown()
    }

    func sendCtrlAltDel() {
        webView.evaluateJavaScript("window.chelate && window.chelate.sendCtrlAltDel()")
    }

    func sendKey(_ name: String) {
        webView.callAsyncJavaScript("window.chelate && window.chelate.sendKey(name)", arguments: ["name": name], in: nil, in: .page)
    }

    private func teardown() {
        generation += 1
        wantsConnect = false
        inbound.removeAll()
        socket?.close()
        socket = nil
        if pageReady {
            webView.evaluateJavaScript("window.chelate && window.chelate.reset()")
        }
    }

    // MARK: - Native → JS

    @ObservationIgnored private var pendingPassword: (String, Int)?

    private func openRFB(password: String, generation: Int) {
        guard pageReady else {
            pendingPassword = (password, generation)
            return
        }
        webView.callAsyncJavaScript("window.chelate.connect(password)", arguments: ["password": password], in: nil, in: .page)
    }

    /// Coalesces WebSocket messages per run loop turn; RFB is a byte stream so concatenation is safe.
    private func enqueue(_ data: Data) {
        inbound.append(data)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.flush()
            }
        }
    }

    private func flush() {
        flushScheduled = false
        guard !inbound.isEmpty else { return }
        var combined = Data()
        for chunk in inbound { combined.append(chunk) }
        inbound.removeAll(keepingCapacity: true)
        webView.callAsyncJavaScript("window.chelate.receive(d)", arguments: ["d": combined.base64EncodedString()], in: nil, in: .page)
    }

    private func handleClose(_ failure: WebSocketConnection.Failure?) {
        let wasConnected = phase == .connected
        flush()
        var code = 1006
        if case .closed(let closeCode, _)? = failure { code = closeCode }
        webView.callAsyncJavaScript("window.chelate.remoteClosed(code, '')", arguments: ["code": code], in: nil, in: .page)
        socket = nil
        switch failure {
        case .certificate(let issue)?:
            connection.certificateIssue = issue
            phase = .disconnected(message: ErrorText.message(for: PVEError.certificate(issue)))
        case .http(let status)?:
            phase = .disconnected(message: handshakeFailureMessage(status: status))
        case .transport(let error)?:
            phase = .disconnected(message: ErrorText.message(for: error))
        case .closed?, nil:
            phase = .disconnected(message: wasConnected ? String(localized: "控制台连接已关闭。") : String(localized: "VNC 连接被服务器关闭。") + tokenHint)
        }
    }

    // MARK: - JS → native

    fileprivate func receive(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
            if case .loadingPage = phase { phase = .connecting }
            if let pending = pendingPassword, pending.1 == generation {
                pendingPassword = nil
                openRFB(password: pending.0, generation: pending.1)
            }
        case "send":
            guard let base64 = body["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            socket?.send(data)
        case "close":
            socket?.close()
            socket = nil
        case "status":
            switch (body["state"] as? String) ?? "" {
            case "connected":
                phase = .connected
            case "securityfailure":
                let reason = body["reason"] as? String ?? ""
                phase = .disconnected(message: String(localized: "VNC 认证失败。") + (reason.isEmpty ? "" : " \(reason)"))
            case "disconnected":
                if phase == .connected {
                    phase = .disconnected(message: String(localized: "控制台连接已断开。"))
                }
                socket?.close()
                socket = nil
            default:
                break
            }
        case "desktopname":
            desktopName = body["name"] as? String
        default:
            break
        }
    }

    // MARK: - Messages

    private var tokenHint: String {
        connection.usesAPIToken
            ? String(localized: "\n\n当前使用 API Token 认证。如果 Token 启用了“权限分离”，需要单独授予 VM.Console 权限；也可以改用账号密码登录后再试。")
            : ""
    }

    private func startFailureMessage(_ error: Error) -> String {
        if case PVEError.forbidden? = error as? PVEError {
            return String(localized: "没有权限打开控制台（需要 VM.Console）。") + tokenHint
        }
        return ErrorText.message(for: error)
    }

    private func handshakeFailureMessage(status: Int) -> String {
        switch status {
        case 401: return String(localized: "WebSocket 认证失败（HTTP 401）。") + tokenHint
        case 403: return String(localized: "没有权限连接控制台（HTTP 403，需要 VM.Console）。") + tokenHint
        default: return String(localized: "无法建立控制台连接（HTTP \(status)）。")
        }
    }
}

/// Avoids the retain cycle WKUserContentController → handler → web view.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: VNCSession?

    init(_ target: VNCSession) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            target?.receive(message)
        }
    }
}

/// Same certificate policy as REST/WebSocket for any HTTPS load; only the bundled page may load.
final class VNCNavigationDelegate: NSObject, WKNavigationDelegate {
    let evaluator: TrustEvaluator

    init(evaluator: TrustEvaluator) {
        self.evaluator = evaluator
    }

    func webView(
        _ webView: WKWebView,
        respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrust.handle(challenge, evaluator: evaluator)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        return scheme == VNCSession.scheme || scheme == "about" ? .allow : .cancel
    }
}

/// Serves `VNCWeb/` from the app bundle under `chelate-vnc://app/` with correct MIME types
/// (ES modules require `text/javascript`).
final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    private let root: URL? = Bundle.main.url(forResource: "VNCWeb", withExtension: nil)

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let root else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let relative = url.path.split(separator: "/").map(String.init)
        guard !relative.isEmpty, !relative.contains(".."), !relative.contains(".") else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let fileURL = relative.reduce(root) { $0.appendingPathComponent($1) }
        guard fileURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(for: fileURL.pathExtension),
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
