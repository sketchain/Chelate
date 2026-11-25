import Foundation
import Observation
import PVEKit

/// A pending second-factor prompt; the UI answers through `resolve`.
struct TFAPrompt: Identifiable {
    let id = UUID()
    let challenge: TFAChallenge
    let continuation: CheckedContinuation<TFAResponse, Error>
}

/// Live connection to one server: client, auth state, cached resources and permissions.
@MainActor
@Observable
final class ServerConnection {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case needsLogin(message: String?)
        case failed(message: String)
    }

    private(set) var config: ServerConfig
    private(set) var state: State = .idle
    private(set) var client: PVEClient
    private(set) var version: VersionInfo?

    // Overview data
    private(set) var resources: [ClusterResource] = []
    private(set) var lastRefresh: Date?
    private(set) var refreshError: String?

    // Prompts
    var tfaPrompt: TFAPrompt?
    var certificateIssue: CertificateTrustFailure?

    // Permissions: effective privileges per ACL path plus privileges denied by a 403.
    private(set) var permissions = PermissionMap(paths: [:])
    private var loadedPermissionPaths: Set<String> = []
    private(set) var deniedActions: Set<String> = []

    let trust: TrustEvaluator
    private let keychain: KeychainStore
    private let onConfigChange: (ServerConfig) -> Void
    private var session: URLSession
    /// Completes once hooks are installed and the persisted ticket is restored.
    @ObservationIgnored private var preparation: Task<Void, Never>?

    init(config: ServerConfig, keychain: KeychainStore, onConfigChange: @escaping (ServerConfig) -> Void) {
        self.config = config
        self.keychain = keychain
        self.onConfigChange = onConfigChange
        let trust = TrustEvaluator(pinned: config.pinnedFingerprint)
        self.trust = trust
        let session = SessionFactory.makeSession(evaluator: trust)
        self.session = session
        client = ServerConnection.makeClient(config: config, keychain: keychain, session: session, trust: trust)
        installHooks()
    }

    private static func makeClient(config: ServerConfig, keychain: KeychainStore, session: URLSession, trust: TrustEvaluator) -> PVEClient {
        if DemoMode.isEnabled && config.id == DemoData.serverID {
            // Fixture-driven fake server: no network, no Keychain.
            let transport = DemoTransport()
            let token = APIToken(userID: config.tokenUserID, tokenID: config.tokenID, secret: "demo")
            let auth = AuthSession(mode: .apiToken(token), endpoint: config.endpoint, transport: transport)
            return PVEClient(endpoint: config.endpoint, auth: auth, transport: transport)
        }
        let transport = LoggingTransport(URLSessionTransport(session: session, trust: trust), label: String(config.id.uuidString.prefix(8)))
        let mode: AuthSession.Mode
        switch config.authMethod {
        case .apiToken:
            let secret = keychain.string(for: config.id, .tokenSecret) ?? ""
            mode = .apiToken(APIToken(userID: config.tokenUserID, tokenID: config.tokenID, secret: secret))
        case .password:
            mode = .password(config.account)
        }
        let auth = AuthSession(mode: mode, endpoint: config.endpoint, transport: transport)
        return PVEClient(endpoint: config.endpoint, auth: auth, transport: transport)
    }

    private func installHooks() {
        let keychain = keychain
        let id = config.id
        let remember = config.rememberPassword
        let hooks = AuthHooks(
            rememberedPassword: {
                remember ? keychain.string(for: id, .password) : nil
            },
            provideTFA: { [weak self] challenge in
                guard let self else { throw PVEError.tfaCancelled }
                return try await self.askForTFA(challenge)
            },
            ticketChanged: { ticket in
                keychain.setTicket(ticket, for: id)
                WidgetMirror.syncTicket(ticket, for: id)
                AppLog.shared.log(.auth, ticket == nil ? "ticket cleared (\(id.uuidString.prefix(8)))" : "ticket updated (\(id.uuidString.prefix(8)))")
            }
        )
        let auth = client.auth
        let stored = config.authMethod == .password ? keychain.ticket(for: id) : nil
        let previous = preparation
        preparation = Task {
            await previous?.value
            await auth.setHooks(hooks)
            await auth.restore(stored)
        }
    }

    /// Rebuilds the client after the configuration changed (host, auth method, pin ...).
    func update(config newConfig: ServerConfig) {
        let needsNewClient = newConfig.endpoint != config.endpoint
            || newConfig.authMethod != config.authMethod
            || newConfig.account != config.account
            || newConfig.tokenUserID != config.tokenUserID
            || newConfig.tokenID != config.tokenID
            || newConfig.rememberPassword != config.rememberPassword
        config = newConfig
        trust.pinned = newConfig.pinnedFingerprint
        if needsNewClient {
            session.invalidateAndCancel()
            session = SessionFactory.makeSession(evaluator: trust)
            client = ServerConnection.makeClient(config: newConfig, keychain: keychain, session: session, trust: trust)
            installHooks()
            state = .idle
            resources = []
            permissions = PermissionMap(paths: [:])
            loadedPermissionPaths = []
            deniedActions = []
        }
    }

    var usesAPIToken: Bool { config.authMethod == .apiToken }

    // MARK: - Connecting

    /// Establishes the session: verifies credentials / ticket by fetching `/version`.
    func connect() async {
        guard state != .connecting else { return }
        state = .connecting
        await preparation?.value
        do {
            if config.authMethod == .password {
                // Ticket missing and no remembered password: ask without hitting the server.
                let hasTicket = await client.auth.currentTicket != nil
                let hasPassword = config.rememberPassword && keychain.string(for: config.id, .password) != nil
                if !hasTicket && !hasPassword {
                    state = .needsLogin(message: nil)
                    return
                }
            }
            version = try await client.version()
            state = .ready
        } catch {
            handleConnectError(error)
        }
    }

    func login(password: String, remember: Bool) async {
        state = .connecting
        if remember != config.rememberPassword {
            var updated = config
            updated.rememberPassword = remember
            config = updated
            onConfigChange(updated)
            installHooks()
        }
        keychain.set(remember ? password : nil, for: config.id, .password)
        await preparation?.value
        sawTFAPrompt = false
        do {
            try await client.auth.login(password: password)
            AppLog.shared.log(.auth, "login succeeded (\(config.id.uuidString.prefix(8)), tfa: \(sawTFAPrompt))")
            if config.usesTFA != sawTFAPrompt {
                var updated = config
                updated.usesTFA = sawTFAPrompt
                config = updated
                onConfigChange(updated)
            }
            WidgetMirror.syncCredentials(for: config, keychain: keychain)
            version = try await client.version()
            state = .ready
        } catch {
            AppLog.shared.log(.auth, "login failed (\(config.id.uuidString.prefix(8))): \(ErrorText.message(for: error))")
            handleConnectError(error)
        }
    }

    func logout() async {
        await client.auth.logout()
        keychain.set(nil, for: config.id, .password)
        WidgetMirror.clearTicket(for: config.id)
        AppLog.shared.log(.auth, "logout (\(config.id.uuidString.prefix(8)))")
        state = .needsLogin(message: nil)
        resources = []
    }

    private func handleConnectError(_ error: Error) {
        AppLog.shared.log(.error, "connect \(config.id.uuidString.prefix(8)): \(ErrorText.message(for: error))")
        if !absorb(error) {
            state = .failed(message: ErrorText.message(for: error))
            return
        }
        switch error as? PVEError {
        case .loginRequired?, .tfaCancelled?:
            state = .needsLogin(message: (error as? PVEError) == .tfaCancelled ? ErrorText.message(for: error) : nil)
        case .unauthorized?:
            if config.authMethod == .password {
                state = .needsLogin(message: ErrorText.message(for: error))
            } else {
                state = .failed(message: ErrorText.message(for: error))
            }
        case .certificate?:
            state = .failed(message: ErrorText.message(for: error))
        default:
            state = .failed(message: ErrorText.message(for: error))
        }
    }

    /// Side effects common to all errors (certificate prompt, login state). Returns true when the
    /// error was recognised.
    @discardableResult
    func absorb(_ error: Error) -> Bool {
        guard let error = error as? PVEError else { return false }
        switch error {
        case .certificate(let failure):
            certificateIssue = failure
        case .loginRequired:
            if state == .ready { state = .needsLogin(message: ErrorText.message(for: error)) }
        default:
            break
        }
        return true
    }

    // MARK: - Certificate trust

    func trustCertificate(_ fingerprint: CertificateFingerprint) {
        var updated = config
        updated.pinnedFingerprint = fingerprint
        config = updated
        trust.pinned = fingerprint
        certificateIssue = nil
        onConfigChange(updated)
        AppLog.shared.log(.auth, "certificate pinned for \(config.id.uuidString.prefix(8)): \(fingerprint.description.prefix(23))…")
    }

    // MARK: - TFA

    /// Set when the server asked for a second factor during the current login.
    @ObservationIgnored private var sawTFAPrompt = false

    private func askForTFA(_ challenge: TFAChallenge) async throws -> TFAResponse {
        sawTFAPrompt = true
        AppLog.shared.log(.auth, "second factor requested (\(config.id.uuidString.prefix(8)))")
        return try await withCheckedThrowingContinuation { continuation in
            tfaPrompt = TFAPrompt(challenge: challenge, continuation: continuation)
        }
    }

    func answerTFA(_ response: TFAResponse?) {
        guard let prompt = tfaPrompt else { return }
        tfaPrompt = nil
        if let response {
            prompt.continuation.resume(returning: response)
        } else {
            prompt.continuation.resume(throwing: PVEError.tfaCancelled)
        }
    }

    // MARK: - Data

    func refreshResources() async {
        guard state == .ready else { return }
        do {
            resources = try await client.clusterResources()
            lastRefresh = Date()
            refreshError = nil
            WidgetMirror.store(resources: resources, server: config)
        } catch PVEError.cancelled {
            // View disappeared.
        } catch is CancellationError {
        } catch {
            absorb(error)
            refreshError = ErrorText.message(for: error)
            AppLog.shared.log(.error, "refresh \(config.id.uuidString.prefix(8)): \(refreshError ?? "")")
        }
    }

    var nodeGroups: [NodeGroup] { NodeGroup.group(resources) }

    func resource(for guest: GuestRef) -> ClusterResource? {
        resources.first { $0.guestRef == guest }
    }

    // MARK: - Permissions

    /// Loads effective privileges for an ACL path once (PVE resolves pools and inheritance).
    func loadPermissions(path: String) async {
        guard !loadedPermissionPaths.contains(path) else { return }
        do {
            let map = try await client.permissions(path: path)
            permissions.merge(map)
            if map.paths[path] == nil {
                // No privileges at all on this path.
                permissions.merge(PermissionMap(paths: [path: []]))
            }
            loadedPermissionPaths.insert(path)
        } catch {
            // Unknown: do not block the UI; a 403 will be handled when the action runs.
        }
    }

    /// Whether an action requiring `privilege` on `path` should be enabled.
    func allows(_ privilege: Privilege, on path: String) -> Bool {
        if deniedActions.contains(key(privilege, path)) { return false }
        guard loadedPermissionPaths.contains(path) else { return true }
        return permissions.allows(privilege, on: path)
    }

    /// Missing privileges for `download-url` (empty when allowed or not yet known).
    func missing(for requirement: DownloadURLRequirement) -> [DownloadURLRequirement.Missing] {
        requirement.missing { allows($0, on: $1) }
    }

    /// Privileges of `needs` that are not granted (empty when allowed or not yet known).
    func missing(_ needs: [PermissionNeed]) -> [PermissionNeed] {
        needs.missing { allows($0, on: $1) }
    }

    func loadPermissions(paths: [String]) async {
        for path in Set(paths) { await loadPermissions(path: path) }
    }

    /// 「缺少 /vms/100 上的 VM.Backup；缺少 /storage/local 上的 Datastore.AllocateSpace」
    static func describe(_ missing: [PermissionNeed]) -> String {
        missing.map { String(localized: "缺少 \($0.path) 上的 \($0.privilege.rawValue)") }
            .joined(separator: String(localized: "；"))
    }

    func markDenied(_ privilege: Privilege, on path: String) {
        deniedActions.insert(key(privilege, path))
    }

    private func key(_ privilege: Privilege, _ path: String) -> String {
        "\(path)|\(privilege.rawValue)"
    }

    /// Runs an action; on 403 marks the privilege as denied and returns a calm message instead
    /// of treating it as a failure.
    func run<T>(_ privilege: Privilege?, on path: String?, _ operation: (PVEClient) async throws -> T) async -> Result<T, ActionError> {
        do {
            return .success(try await operation(client))
        } catch PVEError.forbidden(let message) {
            if let privilege, let path { markDenied(privilege, on: path) }
            return .failure(.forbidden(message))
        } catch {
            absorb(error)
            return .failure(.failed(ErrorText.message(for: error)))
        }
    }
}

enum ActionError: Error, Equatable {
    case forbidden(String?)
    case failed(String)

    var message: String {
        switch self {
        case .forbidden(let detail):
            if let detail, !detail.isEmpty {
                return String(localized: "没有权限执行此操作（\(detail)）。")
            }
            return String(localized: "没有权限执行此操作。")
        case .failed(let message):
            return message
        }
    }

    var isForbidden: Bool {
        if case .forbidden = self { return true }
        return false
    }
}
