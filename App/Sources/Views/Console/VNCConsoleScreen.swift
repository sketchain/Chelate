import PVEKit
import SwiftUI
import WebKit

struct VNCConsoleScreen: View {
    let connection: ServerConnection
    let guest: GuestRef

    @Environment(\.scenePhase) private var scenePhase
    @State private var session: VNCSession?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                WebViewContainer(webView: session.webView)
                    .ignoresSafeArea(.container, edges: .bottom)
                overlay(session)
            }
        }
        .navigationTitle(session?.desktopName ?? String(localized: "控制台 · \(String(guest.vmid))"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("发送 Ctrl+Alt+Del", systemImage: "keyboard") { session?.sendCtrlAltDel() }
                    Button("发送 Esc") { session?.sendKey("Escape") }
                    Button("发送 Tab") { session?.sendKey("Tab") }
                    Divider()
                    Button("重新连接", systemImage: "arrow.clockwise") {
                        Task { await session?.start() }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("控制台操作")
            }
        }
        .task {
            if session == nil {
                let created = VNCSession(connection: connection, guest: guest)
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

    @ViewBuilder
    private func overlay(_ session: VNCSession) -> some View {
        switch session.phase {
        case .loadingPage, .connecting:
            ProgressView("正在连接…")
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        case .connected:
            EmptyView()
        case .disconnected(let message):
            VStack(spacing: 12) {
                Image(systemName: "display.trianglebadge.exclamationmark")
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

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
