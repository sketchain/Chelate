import SwiftUI

@main
struct ChelateApp: App {
    @State private var model: AppModel
    @State private var lock: AppLock

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _lock = State(initialValue: AppLock(enabled: model.settings.faceIDLock))
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environment(model)
                .environment(model.settings)
                .environment(lock)
        }
    }
}

/// Applies theme and accent, the Face ID lock and the app-switcher cover around `RootView`, and
/// handles `chelate://` links.
struct AppShell: View {
    @Environment(AppModel.self) private var model
    @Environment(AppSettings.self) private var settings
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .tint(settings.accent.color)
            .environment(\.chelateAccent, settings.accent.color)
            .overlay {
                if settings.faceIDLock && lock.isLocked {
                    LockScreen()
                        .tint(settings.accent.color)
                        .environment(\.chelateAccent, settings.accent.color)
                } else if settings.faceIDLock && scenePhase != .active {
                    PrivacyCover()
                }
            }
            .preferredColorScheme(settings.theme.colorScheme)
            .onOpenURL { url in model.open(url) }
            .onChange(of: scenePhase, initial: true) { _, phase in
                lock.scenePhaseChanged(phase, enabled: settings.faceIDLock)
            }
    }
}

/// Build metadata injected by CI into Info.plist.
enum BuildInfo {
    private static func value(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("$(") ? nil : trimmed
    }

    static var version: String { value("CFBundleShortVersionString") ?? "0.0.0" }
    static var build: String { value("CFBundleVersion") ?? "0" }
    static var channel: String { value("ChelateChannel") ?? "local" }
    static var commit: String { value("ChelateGitCommit") ?? "unknown" }

    /// 「版本 (build) · 渠道 · commit」
    static var summary: String { "\(version) (\(build)) · \(channel) · \(commit)" }
}
