import Charts
import PVEKit
import SwiftUI

struct RRDChartsView: View {
    enum Source: Hashable {
        case node(String)
        case guest(GuestRef)
    }

    let connection: ServerConnection
    let source: Source

    @State private var timeframe: RRDTimeframe = .hour
    @State private var points: [RRDPoint] = []
    @State private var error: ActionError?
    @State private var loading = false

    var body: some View {
        List {
            Section {
                Picker("时间范围", selection: $timeframe) {
                    ForEach(RRDTimeframe.allCases) { frame in
                        Text(title(frame)).tag(frame)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }
            if let error {
                Section {
                    if error.isForbidden {
                        NoPermissionLabel(text: "无权限查看监控数据")
                    } else {
                        ErrorBanner(message: error.message) { Task { await load() } }
                    }
                }
            }
            if points.isEmpty && loading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
            if !points.isEmpty {
                chartSection("CPU") {
                    SeriesChart(series: [Series(name: String(localized: "CPU"), samples: points.samples(.cpu))], unit: .percent)
                }
                chartSection("内存") {
                    SeriesChart(series: [
                        Series(name: String(localized: "已用"), samples: points.samples(.memoryUsed)),
                        Series(name: String(localized: "总量"), samples: points.samples(.memoryTotal)),
                    ], unit: .bytes)
                }
                chartSection("网络") {
                    SeriesChart(series: [
                        Series(name: String(localized: "入站"), samples: points.samples(.netIn)),
                        Series(name: String(localized: "出站"), samples: points.samples(.netOut)),
                    ], unit: .rate)
                }
                if points.contains(.diskRead) || points.contains(.diskWrite) {
                    chartSection("磁盘 IO") {
                        SeriesChart(series: [
                            Series(name: String(localized: "读取"), samples: points.samples(.diskRead)),
                            Series(name: String(localized: "写入"), samples: points.samples(.diskWrite)),
                        ], unit: .rate)
                    }
                } else if points.contains(.ioWait) {
                    chartSection("IO 等待") {
                        SeriesChart(series: [Series(name: String(localized: "IO 等待"), samples: points.samples(.ioWait))], unit: .percent)
                    }
                }
            }
        }
        .navigationTitle("监控")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: timeframe) { await load() }
    }

    private func chartSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        Section(title) {
            content()
                .frame(height: 180)
                .padding(.vertical, 6)
        }
    }

    private func title(_ frame: RRDTimeframe) -> String {
        switch frame {
        case .hour: return String(localized: "时")
        case .day: return String(localized: "天")
        case .week: return String(localized: "周")
        case .month: return String(localized: "月")
        case .year: return String(localized: "年")
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let frame = timeframe
        let result: Result<[RRDPoint], ActionError>
        switch source {
        case .node(let node):
            result = await connection.run(.sysAudit, on: "/nodes/\(node)") { client in
                try await client.nodeRRD(node: node, timeframe: frame)
            }
        case .guest(let guest):
            result = await connection.run(.vmAudit, on: guest.aclPath) { client in
                try await client.guestRRD(guest, timeframe: frame)
            }
        }
        switch result {
        case .success(let value):
            points = value
            error = nil
        case .failure(let failure):
            error = failure
        }
    }
}

struct Series: Identifiable {
    var id: String { name }
    let name: String
    let samples: [RRDSample]
}

struct SeriesChart: View {
    enum Unit { case percent, bytes, rate }

    let series: [Series]
    let unit: Unit

    var body: some View {
        Chart {
            ForEach(series) { series in
                ForEach(series.samples) { sample in
                    LineMark(
                        x: .value("时间", sample.time),
                        y: .value(series.name, sample.value)
                    )
                    .foregroundStyle(by: .value("系列", series.name))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(label(number))
                    }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartLegend(series.count > 1 ? .visible : .hidden)
    }

    private func label(_ value: Double) -> String {
        switch unit {
        case .percent: return Format.percent(value)
        case .bytes: return Format.bytes(value)
        case .rate: return Format.rate(value)
        }
    }
}
