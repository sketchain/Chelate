import SwiftUI

@main
struct ChelateApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
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
