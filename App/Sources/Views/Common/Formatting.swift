import Foundation
import PVEKit
import SwiftUI

enum Format {
    static func bytes(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }

    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "–" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary) + "/s"
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "–" }
        return fraction.formatted(.percent.precision(.fractionLength(fraction < 0.1 ? 1 : 0)))
    }

    static func uptime(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "–" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "–"
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "–" }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    static func usage(_ used: Double?, _ total: Double?) -> String {
        "\(bytes(used)) / \(bytes(total))"
    }
}

/// Localized names for PVE states and task types.
enum Names {
    static func status(_ raw: String?) -> String {
        switch raw ?? "unknown" {
        case "running": return String(localized: "运行中")
        case "stopped": return String(localized: "已停止")
        case "paused": return String(localized: "已暂停")
        case "suspended": return String(localized: "已休眠")
        case "prelaunch": return String(localized: "准备启动")
        case "online": return String(localized: "在线")
        case "offline": return String(localized: "离线")
        case "available": return String(localized: "可用")
        case "unknown": return String(localized: "未知")
        case let other: return other
        }
    }

    static func power(_ action: PowerAction) -> String {
        switch action {
        case .start: return String(localized: "启动")
        case .shutdown: return String(localized: "关机")
        case .reboot: return String(localized: "重启")
        case .stop: return String(localized: "强制停止")
        case .suspend: return String(localized: "暂停")
        case .resume: return String(localized: "恢复")
        }
    }

    static func powerIcon(_ action: PowerAction) -> String {
        switch action {
        case .start: return "play.fill"
        case .shutdown: return "power"
        case .reboot: return "arrow.clockwise"
        case .stop: return "stop.fill"
        case .suspend: return "pause.fill"
        case .resume: return "playpause.fill"
        }
    }

    static func powerConfirmation(_ action: PowerAction, name: String) -> String {
        switch action {
        case .stop:
            return String(localized: "强制停止“\(name)”相当于直接断电，未保存的数据会丢失。")
        case .reboot:
            return String(localized: "确定要重启“\(name)”吗？")
        case .shutdown:
            return String(localized: "确定要关闭“\(name)”吗？将向系统发送关机请求。")
        default:
            return ""
        }
    }

    static func taskType(_ type: String) -> String {
        switch type {
        case "qmstart", "vzstart": return String(localized: "启动")
        case "qmstop", "vzstop": return String(localized: "停止")
        case "qmshutdown", "vzshutdown": return String(localized: "关机")
        case "qmreboot", "vzreboot": return String(localized: "重启")
        case "qmsuspend", "vzsuspend": return String(localized: "暂停")
        case "qmresume", "vzresume": return String(localized: "恢复")
        case "qmsnapshot", "vzsnapshot": return String(localized: "创建快照")
        case "qmrollback", "vzrollback": return String(localized: "回滚快照")
        case "qmdelsnapshot", "vzdelsnapshot": return String(localized: "删除快照")
        case "vzdump": return String(localized: "备份")
        case "qmigrate", "vzmigrate": return String(localized: "迁移")
        case "vncproxy": return String(localized: "VNC 控制台")
        case "vncshell", "termproxy": return String(localized: "Shell")
        case "qmcreate", "vzcreate": return String(localized: "创建")
        case "qmdestroy", "vzdestroy": return String(localized: "删除")
        case "aptupdate": return String(localized: "更新软件包列表")
        case "startall": return String(localized: "批量启动")
        case "stopall": return String(localized: "批量停止")
        default: return type
        }
    }

    static func guestType(_ type: GuestType) -> String {
        switch type {
        case .qemu: return String(localized: "虚拟机")
        case .lxc: return String(localized: "容器")
        }
    }
}

struct StatusDot: View {
    let status: String?

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityLabel(Names.status(status))
    }

    private var color: Color {
        switch status ?? "unknown" {
        case "running", "online", "available": return .green
        case "paused", "suspended", "prelaunch": return .orange
        case "stopped": return .secondary
        case "offline", "unknown": return .red
        default: return .gray
        }
    }
}

struct UsageBar: View {
    let title: LocalizedStringKey
    let fraction: Double?
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(detail)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)
            ProgressView(value: min(max(fraction ?? 0, 0), 1))
                .tint(tint)
        }
    }

    private var tint: Color {
        guard let fraction else { return .gray }
        if fraction > 0.9 { return .red }
        if fraction > 0.75 { return .orange }
        return .accentColor
    }
}

/// Inline message for permission problems (not an error).
struct NoPermissionLabel: View {
    var text: LocalizedStringKey = "无权限"

    var body: some View {
        Label(text, systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Banner for an error message with optional retry.
struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button("重试", action: retry)
                    .font(.footnote)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
