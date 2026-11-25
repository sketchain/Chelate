import PVEKit
import SwiftUI

/// What a node widget currently shows.
enum NodeWidgetState: Hashable, Sendable {
    /// Fresh data.
    case live
    /// The request failed (e.g. not on the LAN): the cached snapshot is shown greyed out.
    case offline
    /// Password login expired and cannot be renewed without the user.
    case needsLogin
    /// Nothing to show yet (no server, no node, no data).
    case placeholder(String)
}

struct NodeWidgetContent: Hashable, Sendable {
    var snapshot: NodeSnapshot?
    var state: NodeWidgetState
}

enum NodeWidgetFamily: Sendable {
    case small, medium, circular, rectangular
}

/// The widget's views, shared by the widget extension and the in-app widget gallery (demo mode).
/// They draw no background and no outer padding; WidgetKit adds both.
struct NodeWidgetView: View {
    let content: NodeWidgetContent
    let family: NodeWidgetFamily
    var accent: Color = AccentPreset.orange.color
    var now: Date = Date()

    var body: some View {
        switch family {
        case .small:
            SmallNodeWidgetView(content: content, accent: accent, now: now)
        case .medium:
            MediumNodeWidgetView(content: content, accent: accent, now: now)
        case .circular:
            CircularNodeWidgetView(content: content)
        case .rectangular:
            RectangularNodeWidgetView(content: content)
        }
    }
}

enum NodeWidgetText {
    static func percent(_ value: Double) -> String {
        let clamped = max(0, value)
        return "\(Int((clamped * 100).rounded()))%"
    }

    static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        if abs(now.timeIntervalSince(date)) < 60 {
            return String(localized: "刚刚")
        }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func running(_ count: Int) -> String {
        String(localized: "\(count) 台运行")
    }

    /// Footer text on the right: data age, or the offline / login state.
    static func footer(_ content: NodeWidgetContent, now: Date) -> String {
        switch content.state {
        case .needsLogin:
            return String(localized: "打开 App 重新登录")
        case .offline:
            guard let snapshot = content.snapshot else { return String(localized: "离线") }
            return String(localized: "离线 · \(relative(snapshot.fetchedAt, now: now))")
        default:
            guard let snapshot = content.snapshot else { return "" }
            return relative(snapshot.fetchedAt, now: now)
        }
    }

    static func isDimmed(_ content: NodeWidgetContent) -> Bool {
        content.state != .live || content.snapshot?.online == false
    }
}

/// Thin progress bar (WidgetKit-safe, no ProgressView).
struct WidgetBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.22))
                Capsule()
                    .fill(color)
                    .frame(width: max(proxy.size.height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// Status dot + node name, the two bars and the footer (small widget, left half of medium).
struct NodeSummaryView: View {
    let content: NodeWidgetContent
    let accent: Color
    let now: Date

    var body: some View {
        if let snapshot = content.snapshot {
            let dimmed = NodeWidgetText.isDimmed(content)
            let barColor = dimmed ? Color.gray : accent
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(dimmed ? Color.gray : Color.green)
                        .frame(width: 8, height: 8)
                    Text(verbatim: snapshot.node)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 6)
                metric("CPU", snapshot.cpu, color: barColor)
                Spacer(minLength: 6)
                metric("内存", snapshot.memory, color: barColor)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(NodeWidgetText.running(snapshot.runningGuests.count))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(NodeWidgetText.footer(content, now: now))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(content.state == .needsLogin ? Color.orange : Color.secondary)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        } else {
            NodeWidgetPlaceholder(content: content)
        }
    }

    private func metric(_ title: LocalizedStringKey, _ value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: NodeWidgetText.percent(value))
                    .monospacedDigit()
            }
            .font(.caption)
            WidgetBar(fraction: value, color: color)
        }
    }
}

struct NodeWidgetPlaceholder: View {
    let content: NodeWidgetContent

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: content.state == .needsLogin ? "person.crop.circle.badge.exclamationmark" : "server.rack")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(NodeWidgetPlaceholderText.message(content))
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SmallNodeWidgetView: View {
    let content: NodeWidgetContent
    let accent: Color
    let now: Date

    var body: some View {
        NodeSummaryView(content: content, accent: accent, now: now)
    }
}

struct MediumNodeWidgetView: View {
    let content: NodeWidgetContent
    let accent: Color
    let now: Date

    var body: some View {
        if let snapshot = content.snapshot {
            HStack(spacing: 14) {
                NodeSummaryView(content: content, accent: accent, now: now)
                    .frame(maxWidth: .infinity)
                guestList(snapshot)
                    .frame(maxWidth: .infinity)
            }
        } else {
            NodeWidgetPlaceholder(content: content)
        }
    }

    private func guestList(_ snapshot: NodeSnapshot) -> some View {
        let dimmed = NodeWidgetText.isDimmed(content)
        let busiest = Array(snapshot.busiestGuests.prefix(4))
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(busiest) { guest in
                Link(destination: snapshot.guestLink(guest)) {
                    HStack(spacing: 4) {
                        Text(verbatim: guest.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        Text(verbatim: NodeWidgetText.percent(guest.cpu))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .tint(.primary)
            }
            if busiest.isEmpty {
                Text("没有运行中的虚拟机")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            }
            if busiest.count < 4 && !busiest.isEmpty {
                Spacer(minLength: 0)
            }
            Text("+\(snapshot.stoppedCount) 台已停止")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .opacity(dimmed ? 0.6 : 1)
    }
}

struct CircularNodeWidgetView: View {
    let content: NodeWidgetContent

    var body: some View {
        let cpu = content.snapshot?.cpu ?? 0
        Gauge(value: min(max(cpu, 0), 1)) {
            Text(verbatim: "CPU")
        } currentValueLabel: {
            VStack(spacing: -1) {
                Text(verbatim: content.snapshot.map { NodeWidgetText.percent($0.cpu) } ?? "–")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                Text(verbatim: "CPU")
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .opacity(NodeWidgetText.isDimmed(content) ? 0.5 : 1)
    }
}

struct RectangularNodeWidgetView: View {
    let content: NodeWidgetContent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let snapshot = content.snapshot {
                Text(verbatim: "\(snapshot.node) · \(NodeWidgetText.running(snapshot.runningGuests.count))")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(verbatim: "CPU \(NodeWidgetText.percent(snapshot.cpu)) · \(String(localized: "内存")) \(NodeWidgetText.percent(snapshot.memory))")
                    .font(.caption)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if content.state != .live {
                    Text(NodeWidgetText.footer(content, now: Date()))
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(verbatim: "Chelate")
                    .font(.headline)
                Text(NodeWidgetPlaceholderText.message(content))
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(NodeWidgetText.isDimmed(content) && content.snapshot != nil ? 0.7 : 1)
    }
}

enum NodeWidgetPlaceholderText {
    static func message(_ content: NodeWidgetContent) -> String {
        switch content.state {
        case .placeholder(let text): return text
        case .needsLogin: return String(localized: "打开 App 重新登录")
        case .offline: return String(localized: "离线")
        case .live: return ""
        }
    }
}
