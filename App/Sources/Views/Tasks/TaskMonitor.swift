import PVEKit
import SwiftUI

/// A task started by the user (UPID) that is being followed.
struct TrackedTask: Identifiable, Hashable {
    var id: String { upid }
    let upid: String
    let title: String

    var node: String { UPID(upid)?.node ?? "" }
}

/// Polls `/nodes/{node}/tasks/{upid}/status` and the log until the task stops.
struct TaskMonitorSheet: View {
    let connection: ServerConnection
    let task: TrackedTask
    var onFinish: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var status: TaskStatus?
    @State private var log: [TaskLogLine] = []
    @State private var error: String?
    @State private var startedAt = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        stateIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.headline)
                            Text(stateText).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if let status, status.isRunning {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            LabeledContent("已用时间", value: Duration.seconds(context.date.timeIntervalSince(status.starttime ?? startedAt)).formatted(.time(pattern: .minuteSecond)))
                        }
                    }
                }
                if let error {
                    Section { ErrorBanner(message: error) }
                }
                Section("日志") {
                    if log.isEmpty {
                        Text("暂无输出").foregroundStyle(.secondary)
                    }
                    ForEach(log) { line in
                        Text(line.t)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("任务进度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(status?.isRunning == false ? "完成" : "后台运行") { dismiss() }
                }
            }
            .task { await poll() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var stateIcon: some View {
        if let status, !status.isRunning {
            Image(systemName: status.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.title)
                .foregroundStyle(status.succeeded ? .green : .red)
        } else {
            ProgressView().controlSize(.large)
        }
    }

    private var stateText: String {
        guard let status else { return String(localized: "正在获取状态…") }
        if status.isRunning { return String(localized: "执行中…") }
        if status.succeeded {
            return status.exitstatus == "OK" ? String(localized: "成功") : String(localized: "完成（\(status.exitstatus ?? "")）")
        }
        return String(localized: "失败：\(status.exitstatus ?? String(localized: "未知错误"))")
    }

    private func poll() async {
        let node = task.node
        while !Task.isCancelled {
            do {
                let current = try await connection.client.taskStatus(node: node, upid: task.upid)
                status = current
                log = try await connection.client.taskLog(node: node, upid: task.upid)
                error = nil
                if !current.isRunning {
                    onFinish?()
                    return
                }
            } catch PVEError.cancelled {
                return
            } catch is CancellationError {
                return
            } catch {
                connection.absorb(error)
                self.error = ErrorText.message(for: error)
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
