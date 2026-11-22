import PVEKit
import SwiftUI

/// Recent tasks: cluster-wide (`/cluster/tasks`) or for one node / guest.
struct TaskListView: View {
    let connection: ServerConnection
    let node: String?
    let vmid: Int?

    @Environment(\.scenePhase) private var scenePhase
    @State private var tasks: [TaskSummary] = []
    @State private var error: ActionError?
    @State private var loaded = false

    var body: some View {
        List {
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看任务列表")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            if loaded && tasks.isEmpty && error == nil {
                ContentUnavailableView("没有任务", systemImage: "tray")
            }
            ForEach(tasks) { task in
                NavigationLink(value: Route.taskLog(node: task.node, upid: task.upid)) {
                    TaskRow(task: task)
                }
            }
        }
        .navigationTitle(title)
        .refreshable { await load() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var title: String {
        if let vmid { return String(localized: "任务 · \(String(vmid))") }
        if let node { return String(localized: "任务 · \(node)") }
        return String(localized: "任务")
    }

    private func load() async {
        let result = await connection.run(nil, on: nil) { client -> [TaskSummary] in
            if let node {
                return try await client.nodeTasks(node: node, limit: 100, vmid: vmid)
            }
            return try await client.clusterTasks()
        }
        loaded = true
        switch result {
        case .success(let list):
            tasks = list.sorted { $0.startTime > $1.startTime }
            error = nil
        case .failure(let failure):
            if case .failed(let message) = failure, message == ErrorText.message(for: PVEError.cancelled) { return }
            error = failure
        }
    }
}

struct TaskRow: View {
    let task: TaskSummary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(Names.taskType(task.type))
                        .font(.body.weight(.medium))
                    if let id = task.objectID, !id.isEmpty {
                        Text(id).foregroundStyle(.secondary)
                    }
                }
                Text("\(task.node) · \(task.user)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(task.startTime.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let status = task.status, !task.succeeded {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if task.isRunning {
            ProgressView()
        } else if task.succeeded {
            Image(systemName: task.status == "OK" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(task.status == "OK" ? .green : .orange)
        } else {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

struct TaskLogView: View {
    let connection: ServerConnection
    let node: String
    let upid: String

    @State private var status: TaskStatus?
    @State private var lines: [TaskLogLine] = []
    @State private var error: ActionError?

    var body: some View {
        List {
            Section {
                if let status {
                    LabeledContent("类型", value: Names.taskType(status.type ?? ""))
                    if let id = status.id, !id.isEmpty { LabeledContent("对象", value: id) }
                    if let user = status.user { LabeledContent("用户", value: user) }
                    LabeledContent("开始", value: Format.date(status.starttime))
                    LabeledContent("状态") {
                        if status.isRunning {
                            HStack { ProgressView(); Text("执行中") }
                        } else {
                            Text(status.exitstatus ?? "–")
                                .foregroundStyle(status.succeeded ? .green : .red)
                        }
                    }
                } else if error == nil {
                    ProgressView()
                }
            }
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看此任务")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            Section("日志") {
                ForEach(lines) { line in
                    Text(line.t)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section {
                Text(upid)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("任务日志")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            while !Task.isCancelled {
                await load()
                if status?.isRunning != true { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func load() async {
        let result = await connection.run(nil, on: nil) { client -> (TaskStatus, [TaskLogLine]) in
            async let status = client.taskStatus(node: node, upid: upid)
            async let log = client.taskLog(node: node, upid: upid, start: 0, limit: 5000)
            return try await (status, log)
        }
        switch result {
        case .success(let (status, lines)):
            self.status = status
            self.lines = lines
            error = nil
        case .failure(let failure):
            error = failure
        }
    }
}
