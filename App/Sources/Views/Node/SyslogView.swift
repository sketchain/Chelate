import PVEKit
import SwiftUI

/// 「系统日志」: the node's journal through `/nodes/{node}/journal` (the WebUI's System Log panel),
/// newest at the bottom; scrolling to the top loads older lines (`endcursor`), pull to refresh
/// fetches newer ones (`startcursor`). Keyword search filters the loaded lines; a time range
/// switches to `since` / `until` like the WebUI's range mode.
struct SyslogView: View {
    let connection: ServerConnection
    let node: String

    static let pageSize = 500

    @State private var entries: [JournalEntry] = []
    @State private var oldestCursor: String?
    @State private var newestCursor: String?
    @State private var loadingOlder = false
    @State private var reachedStart = false
    @State private var error: ActionError?
    @State private var loaded = false
    @State private var keyword = ""
    @State private var useRange = false
    @State private var since = Calendar.current.startOfDay(for: Date())
    @State private var until = Date()
    @State private var showRange = false
    @State private var nextID = 0

    private var aclPath: String { PermissionNeed.node(node) }
    private var shown: [JournalEntry] { entries.matching(keyword) }

    var body: some View {
        let missing = connection.missing([PermissionNeed(.sysSyslog, on: aclPath)])
        ScrollViewReader { proxy in
            List {
                if !missing.isEmpty {
                    Section { MissingPermissionLabel(action: "查看系统日志", missing: missing) }
                }
                if let error, missing.isEmpty {
                    Section {
                        if error.isForbidden {
                            NoPermissionLabel(text: "无权限查看系统日志（需要 Sys.Syslog）")
                        } else {
                            ErrorBanner(message: error.message) { Task { await reload() } }
                        }
                    }
                }
                if useRange {
                    Section {
                        Button {
                            showRange = true
                        } label: {
                            Label("\(Format.shortDate(since)) – \(Format.shortDate(until))", systemImage: "calendar")
                        }
                    }
                } else if loaded && !reachedStart && !entries.isEmpty {
                    HStack {
                        Spacer()
                        if loadingOlder { ProgressView() } else { Text("上滑加载更早的记录").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }
                    .onAppear { Task { await loadOlder(proxy: proxy) } }
                    .listRowBackground(Color.clear)
                }
                if !loaded && error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if loaded && shown.isEmpty {
                    Text(keyword.isEmpty ? "没有日志或未选择时间范围" : "没有匹配的记录")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { entry in
                    Text(verbatim: entry.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(color(entry))
                        .textSelection(.enabled)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
                        .id(entry.id)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .accessibilityIdentifier("syslog-list")
            .searchable(text: $keyword, prompt: Text("搜索关键词"))
            .navigationTitle("系统日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("最新记录", systemImage: "clock.arrow.circlepath") {
                            useRange = false
                            Task { await reload(proxy: proxy) }
                        }
                        Button("按时间范围…", systemImage: "calendar") { showRange = true }
                    } label: {
                        Image(systemName: useRange ? "calendar.badge.clock" : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable {
                if useRange { await reload(proxy: proxy) } else { await loadNewer(proxy: proxy) }
            }
            .task {
                await connection.loadPermissions(path: aclPath)
                await reload(proxy: proxy)
            }
            .sheet(isPresented: $showRange) {
                SyslogRangeSheet(since: since, until: until) { from, to in
                    since = from
                    until = to
                    useRange = true
                    Task { await reload(proxy: proxy) }
                }
            }
        }
    }

    private func color(_ entry: JournalEntry) -> Color {
        if entry.isReboot { return .accentColor }
        switch entry.priority ?? 6 {
        case 0...3: return .red
        case 4: return .orange
        case 7: return .secondary
        default: return .primary
        }
    }

    private func fetch(_ query: JournalQuery) async -> JournalPage? {
        let offset = nextID
        let result = await connection.run(.sysSyslog, on: aclPath) { client in
            try await client.journal(node: node, query, idOffset: offset)
        }
        switch result {
        case .success(let page):
            nextID += page.entries.count
            error = nil
            return page
        case .failure(let failure):
            if case .failed(let text) = failure, text == ErrorText.message(for: PVEError.cancelled) { return nil }
            error = failure
            return nil
        }
    }

    private func reload(proxy: ScrollViewProxy? = nil) async {
        let query: JournalQuery = useRange ? .range(since: since, until: until) : .latest(count: Self.pageSize)
        guard let page = await fetch(query) else { loaded = true; return }
        entries = page.entries
        oldestCursor = page.oldestCursor
        newestCursor = page.newestCursor
        reachedStart = useRange || page.entries.count < Self.pageSize
        loaded = true
        if let last = entries.last { proxy?.scrollTo(last.id, anchor: .bottom) }
    }

    private func loadOlder(proxy: ScrollViewProxy) async {
        guard !loadingOlder, !useRange, let cursor = oldestCursor else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        guard let page = await fetch(.older(than: cursor, count: Self.pageSize)) else { return }
        // The line at the cursor itself comes back again; drop duplicates by text.
        let firstText = entries.first?.text
        var older = page.entries
        if let last = older.last, last.text == firstText { older.removeLast() }
        let anchor = entries.first?.id
        entries = older + entries
        if page.oldestCursor != nil { oldestCursor = page.oldestCursor }
        if older.isEmpty || page.entries.count < Self.pageSize { reachedStart = true }
        if let anchor { proxy.scrollTo(anchor, anchor: .top) }
    }

    private func loadNewer(proxy: ScrollViewProxy) async {
        guard let cursor = newestCursor else { await reload(proxy: proxy); return }
        guard let page = await fetch(.newer(than: cursor)) else { return }
        var newer = page.entries
        if let first = newer.first, first.text == entries.last?.text { newer.removeFirst() }
        entries += newer
        if page.newestCursor != nil { newestCursor = page.newestCursor }
        if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
    }
}

struct SyslogRangeSheet: View {
    @State var since: Date
    @State var until: Date
    let onApply: (Date, Date) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("开始", selection: $since, in: ...until)
                DatePicker("结束", selection: $until, in: since...)
            }
            .navigationTitle("时间范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        onApply(since, until)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 「更新」: upgradable packages (`apt/update`), changelog per package, 「刷新」 (apt update, task)
/// and 「升级」 (node shell running the WebUI's upgrade command, root@pam only).
struct AptUpdatesView: View {
    let connection: ServerConnection
    let node: String

    @State private var packages: [AptPackage] = []
    @State private var loaded = false
    @State private var error: ActionError?
    @State private var tracked: TrackedTask?
    @State private var changelog: AptPackage?
    @State private var message: String?

    private var aclPath: String { PermissionNeed.node(node) }
    private var isRootSession: Bool { connection.client.auth.authID == "root@pam" && !connection.usesAPIToken }

    var body: some View {
        let modifyMissing = connection.missing([PermissionNeed(.sysModify, on: aclPath)])
        let consoleMissing = connection.missing([PermissionNeed(.sysConsole, on: aclPath)])
        List {
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看更新（需要 Sys.Modify）")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            Section {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!modifyMissing.isEmpty)
                .accessibilityIdentifier("apt-refresh")
                NavigationLink(value: Route.console(.nodeUpgrade(node: node))) {
                    Label("升级", systemImage: "arrow.up.circle")
                }
                .disabled(!consoleMissing.isEmpty || !isRootSession)
                .accessibilityIdentifier("apt-upgrade")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    MissingPermissionLabel(action: "刷新", missing: modifyMissing)
                    if !consoleMissing.isEmpty {
                        MissingPermissionLabel(action: "升级", missing: consoleMissing)
                    } else if !isRootSession {
                        NoPermissionLabel(text: "升级只对 root@pam 账号密码登录可用（与 PVE 网页一致）。")
                    } else {
                        Text("“刷新”执行 apt update；“升级”打开节点 Shell 并执行 apt dist-upgrade。")
                    }
                }
            }
            Section {
                if !loaded && error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if loaded && packages.isEmpty && error == nil {
                    Text("没有可用的更新").foregroundStyle(.secondary)
                }
                ForEach(packages) { package in
                    Button { changelog = package } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(verbatim: package.name).font(.body)
                                Spacer(minLength: 8)
                                if let origin = package.origin {
                                    Text(verbatim: origin).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(verbatim: package.versionChange)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("apt-package")
                }
            } header: {
                if !packages.isEmpty { Text("可更新的软件包（\(packages.count)）") }
            } footer: {
                if !packages.isEmpty { Text("点按软件包查看更新日志。") }
            }
        }
        .navigationTitle("更新")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            await connection.loadPermissions(path: aclPath)
            await load()
        }
        .sheet(item: $tracked) { task in
            TaskMonitorSheet(connection: connection, task: task) { Task { await load() } }
        }
        .sheet(item: $changelog) { package in
            AptChangelogView(connection: connection, node: node, package: package)
        }
        .alert("操作未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") {}
        } message: {
            Text(message ?? "")
        }
    }

    private func load() async {
        let result = await connection.run(.sysModify, on: aclPath) { client in
            try await client.aptUpdates(node: node)
        }
        loaded = true
        switch result {
        case .success(let list):
            packages = list
            error = nil
        case .failure(let failure):
            if case .failed(let text) = failure, text == ErrorText.message(for: PVEError.cancelled) { return }
            error = failure
        }
    }

    private func refresh() async {
        let result = await connection.run(.sysModify, on: aclPath) { client in
            try await client.aptRefresh(node: node)
        }
        switch result {
        case .success(let upid):
            tracked = TrackedTask(upid: upid, title: String(localized: "刷新软件包列表"))
        case .failure(let failure):
            message = failure.message
        }
    }
}

struct AptChangelogView: View {
    let connection: ServerConnection
    let node: String
    let package: AptPackage
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let text {
                    Text(verbatim: text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else if let error {
                    ErrorBanner(message: error).padding()
                } else {
                    ProgressView().padding()
                }
            }
            .navigationTitle(package.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task {
                let result = await connection.run(.sysModify, on: PermissionNeed.node(node)) { client in
                    try await client.aptChangelog(node: node, package: package)
                }
                switch result {
                case .success(let value): text = value
                case .failure(let failure): error = failure.message
                }
            }
        }
    }
}
