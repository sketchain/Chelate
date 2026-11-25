import LocalAuthentication
import Observation
import SwiftUI
import UIKit

/// Face ID / passcode lock (Settings › 安全 › Face ID 解锁).
///
/// Locked on cold launch and when the app returns after more than 5 minutes in the background.
/// While the lock is enabled a cover hides the content whenever the scene is not active, so the
/// app switcher never shows server data.
@MainActor
@Observable
final class AppLock {
    static let gracePeriod: TimeInterval = 5 * 60

    private(set) var isLocked: Bool
    private(set) var isAuthenticating = false
    private(set) var lastError: String?
    @ObservationIgnored private var backgroundedAt: Date?

    init(enabled: Bool) {
        isLocked = enabled && !DemoMode.isEnabled
    }

    func scenePhaseChanged(_ phase: ScenePhase, enabled: Bool) {
        guard enabled, !DemoMode.isEnabled else {
            isLocked = false
            return
        }
        switch phase {
        case .background:
            // Face ID's own sheet makes the scene inactive, never background.
            if backgroundedAt == nil { backgroundedAt = Date() }
        case .active:
            if let since = backgroundedAt, Date().timeIntervalSince(since) > Self.gracePeriod {
                isLocked = true
            }
            backgroundedAt = nil
            if isLocked && !isAuthenticating {
                Task { await unlock() }
            }
        default:
            break
        }
    }

    /// Asks for Face ID / Touch ID with passcode fallback.
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await Self.authenticate(reason: String(localized: "解锁 Chelate")) {
            isLocked = false
            lastError = nil
            AppLog.shared.log(.auth, "app unlocked")
        } else {
            lastError = String(localized: "未能验证身份。")
        }
    }

    /// Turning the lock off unlocks immediately.
    func disable() {
        isLocked = false
        backgroundedAt = nil
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Face ID"
        }
    }
}

/// Shown while locked: the wordmark and an unlock button.
struct LockScreen: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ChelateWordmark()
            Image(systemName: "lock.fill")
                .font(.title)
                .foregroundStyle(.secondary)
            if let error = lock.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await lock.unlock() }
            } label: {
                Text("解锁")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(lock.isAuthenticating)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("lock-screen")
    }
}

/// Opaque cover for the app switcher while the lock is enabled.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
        .ignoresSafeArea()
    }
}
