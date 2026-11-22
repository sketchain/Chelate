import SwiftUI

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("Chelate")
                        .font(.title2.bold())
                    Text("Proxmox VE 客户端")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section("版本") {
                Text(BuildInfo.summary)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                LabeledContent("版本", value: BuildInfo.version)
                LabeledContent("Build", value: BuildInfo.build)
                LabeledContent("渠道", value: BuildInfo.channel)
                LabeledContent("Commit", value: BuildInfo.commit)
            }
            Section("开源组件") {
                LabeledContent("SwiftTerm", value: "MIT")
                LabeledContent("noVNC", value: "MPL-2.0")
            }
            Section {
                Text("适配 Proxmox VE 9.x。所有 API 请求直接发往你的服务器，不经过任何第三方。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("关于")
    }
}
