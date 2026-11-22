import Foundation
import PVEKit

/// Turns errors into Chinese messages a person can act on.
enum ErrorText {
    static func message(for error: Error) -> String {
        if let error = error as? PVEError {
            return message(for: error)
        }
        if let failure = error as? CertificateTrustFailure {
            return message(for: PVEError.certificate(failure))
        }
        if let urlError = error as? URLError {
            return message(for: PVEError.from(urlError: urlError))
        }
        if error is CancellationError {
            return String(localized: "操作已取消。")
        }
        return error.localizedDescription
    }

    static func message(for error: PVEError) -> String {
        switch error {
        case .network(let failure):
            return networkMessage(failure)
        case .certificate(.untrusted(let info)):
            return String(localized: "服务器证书不受系统信任（\(info.host)）。请核对指纹后决定是否信任。")
        case .certificate(.fingerprintMismatch):
            return String(localized: "警告：服务器证书指纹与之前确认的不一致！可能是证书已更换，也可能存在中间人攻击。连接已阻止。")
        case .unauthorized:
            return String(localized: "认证失败：用户名、密码或 API Token 不正确，或登录已失效。")
        case .forbidden(let message):
            if let message, !message.isEmpty {
                return String(localized: "没有权限执行此操作（\(message)）。")
            }
            return String(localized: "没有权限执行此操作。")
        case .notFound(let message):
            return String(localized: "资源不存在。") + suffix(message)
        case .http(let status, let message):
            switch status {
            case 595:
                return String(localized: "集群内转发失败：目标节点不可达。") + suffix(message)
            case 596:
                return String(localized: "集群内转发失败：连接目标节点出错。") + suffix(message)
            case 500..<600:
                return String(localized: "服务器内部错误（HTTP \(status)）。") + suffix(message)
            default:
                return String(localized: "请求失败（HTTP \(status)）。") + suffix(message)
            }
        case .decoding(let detail):
            return String(localized: "无法解析服务器响应（\(detail)）。服务器版本可能不兼容。")
        case .invalidEndpoint:
            return String(localized: "服务器地址或端口无效。")
        case .loginRequired:
            return String(localized: "登录已过期，请重新输入密码。")
        case .tfaUnsupported:
            return String(localized: "该账号只配置了 WebAuthn/U2F 等本 App 不支持的二次验证方式。请在 PVE 中添加 TOTP 或恢复码，或改用 API Token。")
        case .tfaCancelled:
            return String(localized: "已取消二次验证。")
        case .consoleUnavailable(let reason):
            return reason
        case .cancelled:
            return String(localized: "操作已取消。")
        }
    }

    static func networkMessage(_ failure: NetworkFailure) -> String {
        switch failure {
        case .offline:
            return String(localized: "设备未连接网络。")
        case .timedOut:
            return String(localized: "连接超时：服务器无响应，请检查地址、端口和网络。")
        case .cannotFindHost:
            return String(localized: "找不到服务器：主机名无法解析。")
        case .cannotConnect:
            return String(localized: "无法连接服务器：请确认 PVE 正在运行、端口（默认 8006）正确，且手机与服务器网络互通。")
        case .connectionLost:
            return String(localized: "网络连接中断。")
        case .localNetworkDenied:
            return String(localized: "无法访问局域网：请在“设置 › 隐私与安全性 › 本地网络”中允许 Chelate。")
        case .tls(let detail):
            return String(localized: "安全连接失败（\(detail)）。")
        case .other(let detail):
            return String(localized: "网络错误：\(detail)")
        }
    }

    private static func suffix(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        return " " + message
    }
}
