import Foundation

/// What to tell the user before opening a console, derived from pve-manager's behaviour:
///
/// - `termproxy` and `vncwebsocket` accept API tokens (the WebSocket upgrade is authenticated by
///   pveproxy exactly like REST calls, and termproxy verifies the ticket via
///   `POST /access/vncticket`, which accepts token ids). Browsers cannot send the token header on a
///   WebSocket, which is why the web UI cannot; a native client can.
/// - The node shell only runs `login -f root` (no password prompt) for exactly `root@pam`.
///   Everyone else — including tokens of root (`root@pam!name`) — gets `/bin/login` and must type
///   a Linux username and password (`get_shell_command` in `PVE/API2/Nodes.pm`).
/// - Tokens with privilege separation need their own `Sys.Console` / `VM.Console` ACL.
public enum ConsoleAdvisory: Sendable, Hashable {
    case none
    /// Node shell will show a `login:` prompt because the session is not `root@pam`.
    case nodeShellRequiresLogin(viaToken: Bool)

    public static func evaluate(target: ConsoleTarget, authID: String, usesToken: Bool) -> ConsoleAdvisory {
        switch target {
        case .nodeShell:
            if usesToken || authID != "root@pam" {
                return .nodeShellRequiresLogin(viaToken: usesToken)
            }
            return .none
        case .lxc:
            return .none
        }
    }
}
