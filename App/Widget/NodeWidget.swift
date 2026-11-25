import AppIntents
import SwiftUI
import UIKit
import WidgetKit

struct NodeEntry: TimelineEntry {
    var date: Date
    var content: NodeWidgetContent
    var accent: AccentPreset
}

struct NodeTimelineProvider: AppIntentTimelineProvider {
    typealias Entry = NodeEntry
    typealias Intent = NodeWidgetIntent

    /// About every 15 minutes (WidgetKit may delay it).
    static let refreshInterval: TimeInterval = 15 * 60

    func placeholder(in context: Context) -> NodeEntry {
        NodeEntry(date: Date(), content: NodeWidgetContent(snapshot: .demo(), state: .live), accent: .orange)
    }

    func snapshot(for configuration: NodeWidgetIntent, in context: Context) async -> NodeEntry {
        if context.isPreview && SharedContainer.loadServers().isEmpty {
            return placeholder(in: context)
        }
        return await entry(for: configuration)
    }

    func timeline(for configuration: NodeWidgetIntent, in context: Context) async -> Timeline<NodeEntry> {
        let entry = await entry(for: configuration)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(Self.refreshInterval)))
    }

    private func entry(for configuration: NodeWidgetIntent) async -> NodeEntry {
        let accent = SharedContainer.loadSettings().accent
        func make(_ snapshot: NodeSnapshot?, _ state: NodeWidgetState) -> NodeEntry {
            NodeEntry(date: Date(), content: NodeWidgetContent(snapshot: snapshot, state: state), accent: accent)
        }
        guard SharedContainer.isAvailable else {
            return make(nil, .placeholder(String(localized: "App Group 不可用，请检查签名")))
        }
        let servers = SharedContainer.loadServers()
        guard !servers.isEmpty else {
            return make(nil, .placeholder(String(localized: "在 Chelate 中添加服务器")))
        }
        // Server: the chosen one, else the chosen node's, else the first.
        let serverID = configuration.server?.id ?? configuration.node?.serverID
        guard let server = servers.first(where: { $0.id == serverID }) ?? servers.first else {
            return make(nil, .placeholder(String(localized: "长按小组件选择服务器")))
        }
        let node: String
        if let chosen = configuration.node, chosen.serverID == server.id {
            node = chosen.node
        } else if let first = SharedContainer.knownNodes(server: server.id).first {
            node = first
        } else {
            return make(nil, .placeholder(String(localized: "打开 Chelate 加载“\(server.displayName)”的节点")))
        }

        let cached = SharedContainer.cachedSnapshot(server: server.id, node: node)
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < NodeWidgetLoader.cacheFreshness {
            return make(cached, .live)
        }
        switch await NodeWidgetLoader.load(server: server, node: node) {
        case .success(let snapshot):
            SharedContainer.store([snapshot])
            return make(snapshot, .live)
        case .needsLogin:
            return make(cached, .needsLogin)
        case .failure:
            return make(cached, cached == nil ? .placeholder(String(localized: "无法连接“\(server.displayName)”")) : .offline)
        }
    }
}

struct NodeWidgetEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    let entry: NodeEntry

    private var family: NodeWidgetFamily {
        switch widgetFamily {
        case .systemMedium: return .medium
        case .accessoryCircular: return .circular
        case .accessoryRectangular: return .rectangular
        default: return .small
        }
    }

    var body: some View {
        NodeWidgetView(content: entry.content, family: family, accent: entry.accent.color, now: entry.date)
            .widgetURL(entry.content.snapshot?.nodeLink)
            .containerBackground(for: .widget) {
                Color(uiColor: .systemBackground)
            }
    }
}

struct NodeWidget: Widget {
    static let kind = "org.sketchain.chelate.node"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: NodeWidgetIntent.self, provider: NodeTimelineProvider()) { entry in
            NodeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("节点状态")
        .description("Proxmox VE 节点的 CPU、内存和运行中的虚拟机。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct ChelateWidgetBundle: WidgetBundle {
    var body: some Widget {
        NodeWidget()
    }
}
