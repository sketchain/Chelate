import PVEKit
import SwiftTerm
import SwiftUI
import UIKit

struct TerminalScreen: View {
    let connection: ServerConnection
    let target: ConsoleTarget

    @Environment(\.scenePhase) private var scenePhase
    @State private var session: TerminalSession?
    @State private var showAdvisory = true

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                if showAdvisory, case .nodeShellRequiresLogin(let viaToken) = session.advisory {
                    advisoryBanner(viaToken: viaToken)
                }
                ZStack {
                    TerminalViewRepresentable(session: session)
                        .ignoresSafeArea(.container, edges: .bottom)
                    overlay(session)
                }
            }
        }
        .background(Color.black)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("重新连接", systemImage: "arrow.clockwise") {
                    Task { await session?.start() }
                }
                .disabled(session?.phase == .connecting)
            }
        }
        .task {
            if session == nil {
                let created = TerminalSession(connection: connection, target: target)
                session = created
                await created.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let session else { return }
            switch phase {
            case .background:
                session.suspend()
            case .active:
                if session.shouldReconnect {
                    Task { await session.start() }
                }
            default:
                break
            }
        }
        .onDisappear {
            session?.stop()
        }
    }

    private var title: String {
        switch target {
        case .nodeShell(let node): return "Shell · \(node)"
        case .lxc(let guest): return String(localized: "控制台 · \(String(guest.vmid))")
        }
    }

    private func advisoryBanner(viaToken: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(viaToken
                 ? "当前使用 API Token 连接。PVE 只为 root@pam 账号密码登录提供免密 Shell，Token 会话会先出现 login: 提示，需要输入节点上的 Linux 用户名和密码。"
                 : "PVE 只为 root@pam 提供免密 Shell，当前账号会先出现 login: 提示，需要输入节点上的 Linux 用户名和密码。")
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showAdvisory = false
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("关闭提示")
        }
        .padding(10)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func overlay(_ session: TerminalSession) -> some View {
        switch session.phase {
        case .idle, .connecting:
            ProgressView("正在连接…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .connected:
            EmptyView()
        case .disconnected(let message):
            VStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.largeTitle)
                Text(message ?? String(localized: "已断开连接。"))
                    .multilineTextAlignment(.center)
                    .font(.callout)
                Button("重新连接") {
                    Task { await session.start() }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }
}

/// Hosts SwiftTerm's `TerminalView`. Its default input accessory provides Esc, Ctrl, Tab,
/// arrows and function keys above the iOS keyboard.
struct TerminalViewRepresentable: UIViewRepresentable {
    let session: TerminalSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.terminalDelegate = context.coordinator
        view.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        view.optionAsMetaKey = true
        session.terminalView = view
        DispatchQueue.main.async {
            _ = view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if session.terminalView !== view {
            session.terminalView = view
        }
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession

        init(session: TerminalSession) {
            self.session = session
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated {
                session.resize(cols: newCols, rows: newRows)
            }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated {
                session.sendInput(data)
            }
        }

        func scrolled(source: TerminalView, position: Double) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            MainActor.assumeIsolated {
                UIApplication.shared.open(url)
            }
        }

        func bell(source: TerminalView) {
            MainActor.assumeIsolated {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                MainActor.assumeIsolated {
                    UIPasteboard.general.string = text
                }
            }
        }

        func clipboardRead(source: TerminalView) -> Data? {
            nil
        }

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
