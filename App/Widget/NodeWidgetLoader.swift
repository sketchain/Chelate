import Foundation
import PVEKit

/// Fetches a node snapshot for the widget with the same certificate pinning as the app
/// (`TrustEvaluator` with the mirrored pin, `ServerTrust` in the session delegate).
///
/// - API token: used directly.
/// - Password: the mirrored ticket; PVEKit renews it before it expires. Once expired, a full login
///   happens only with a remembered password and an account without TFA; otherwise the widget
///   asks to open the app.
enum NodeWidgetLoader {
    enum Outcome {
        case success(NodeSnapshot)
        case needsLogin
        case failure(String)
    }

    /// Use the app's cached data instead of hitting the server when it is this fresh.
    static let cacheFreshness: TimeInterval = 120

    static func load(server: ServerConfig, node: String) async -> Outcome {
        let keychain = SharedContainer.keychain
        let trust = TrustEvaluator(pinned: server.pinnedFingerprint)
        let session = SessionFactory.makeSession(evaluator: trust)
        defer { session.finishTasksAndInvalidate() }
        let transport = URLSessionTransport(session: session, trust: trust)

        let mode: AuthSession.Mode
        switch server.authMethod {
        case .apiToken:
            guard let secret = keychain.string(for: server.id, .tokenSecret), !secret.isEmpty else { return .needsLogin }
            mode = .apiToken(APIToken(userID: server.tokenUserID, tokenID: server.tokenID, secret: secret))
        case .password:
            mode = .password(server.account)
        }

        let id = server.id
        let canRelogin = server.rememberPassword && !server.usesTFA
        let hooks = AuthHooks(
            rememberedPassword: {
                canRelogin ? keychain.string(for: id, .password) : nil
            },
            provideTFA: { _ in
                // A widget cannot ask for a second factor.
                throw PVEError.tfaCancelled
            },
            ticketChanged: { ticket in
                if let ticket { keychain.setTicket(ticket, for: id) }
            }
        )
        let auth = AuthSession(mode: mode, endpoint: server.endpoint, transport: transport, hooks: hooks)
        if server.authMethod == .password {
            guard let ticket = keychain.ticket(for: id) else {
                if !canRelogin || keychain.string(for: id, .password) == nil { return .needsLogin }
                return await fetch(server: server, node: node, auth: auth, transport: transport)
            }
            await auth.restore(ticket)
        }
        return await fetch(server: server, node: node, auth: auth, transport: transport)
    }

    private static func fetch(server: ServerConfig, node: String, auth: AuthSession, transport: any HTTPTransport) async -> Outcome {
        let client = PVEClient(endpoint: server.endpoint, auth: auth, transport: transport)
        do {
            async let status = client.nodeStatus(node: node)
            async let guests = client.nodeGuests(node: node)
            let (nodeStatus, lists) = try await (status, guests)
            var all: [NodeSnapshot.Guest] = []
            for item in lists.qemu {
                guard let vmid = item.vmid else { continue }
                all.append(NodeSnapshot.Guest(
                    vmid: vmid,
                    name: item.name ?? String(vmid),
                    type: .qemu,
                    status: item.status ?? "unknown",
                    cpu: item.cpu ?? 0,
                    template: item.template ?? false
                ))
            }
            for item in lists.lxc {
                guard let vmid = item.vmid else { continue }
                all.append(NodeSnapshot.Guest(
                    vmid: vmid,
                    name: item.name ?? String(vmid),
                    type: .lxc,
                    status: item.status ?? "unknown",
                    cpu: item.cpu ?? 0,
                    template: item.template ?? false
                ))
            }
            let snapshot = NodeSnapshot(
                serverID: server.id,
                serverName: server.displayName,
                node: node,
                online: true,
                cpu: nodeStatus.cpu ?? 0,
                memoryUsed: nodeStatus.memory?.used ?? 0,
                memoryTotal: nodeStatus.memory?.total ?? 0,
                guests: all.sorted { $0.vmid < $1.vmid },
                fetchedAt: Date()
            )
            return .success(snapshot)
        } catch let error as PVEError {
            switch error {
            case .loginRequired, .tfaCancelled, .tfaUnsupported:
                return .needsLogin
            case .unauthorized where server.authMethod == .password:
                return .needsLogin
            default:
                return .failure(String(describing: error))
            }
        } catch {
            return .failure(String(describing: error))
        }
    }
}
