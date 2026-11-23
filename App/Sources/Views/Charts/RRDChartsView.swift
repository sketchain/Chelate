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
                chartSection("CPU", id: "cpu") {
                    SeriesChart(
                        series: [Series(name: String(localized: "CPU"), color: .blue, samples: points.samples(.cpu))],
                        unit: .percent,
                        timeframe: timeframe,
                        pinnedSelection: DemoMode.pinsChartSelection ? middleTime(.cpu) : nil
                    )
                }
                chartSection("内存", id: "memory") {
                    SeriesChart(series: memorySeries, unit: .bytes, timeframe: timeframe)
                }
                chartSection("网络", id: "network") {
                    SeriesChart(series: present([
                        Series(name: String(localized: "入站"), color: .blue, samples: points.samples(.netIn)),
                        Series(name: String(localized: "出站"), color: .orange, samples: points.samples(.netOut)),
                    ]), unit: .rate, timeframe: timeframe)
                }
                if points.contains(.diskRead) || points.contains(.diskWrite) {
                    chartSection("磁盘 IO", id: "disk") {
                        SeriesChart(series: present([
                            Series(name: String(localized: "读取"), color: .blue, samples: points.samples(.diskRead)),
                            Series(name: String(localized: "写入"), color: .orange, samples: points.samples(.diskWrite)),
                        ]), unit: .rate, timeframe: timeframe)
                    }
                } else if points.contains(.ioWait) {
                    chartSection("IO 等待", id: "iowait") {
                        SeriesChart(
                            series: [Series(name: String(localized: "IO 等待"), color: .blue, samples: points.samples(.ioWait))],
                            unit: .percent,
                            timeframe: timeframe
                        )
                    }
                }
            }
        }
        .navigationTitle("监控")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: timeframe) { await load() }
    }

    /// Node: total (green), available (cyan), used (blue), ZFS ARC (orange).
    /// Guest: used and total, plus host memory for QEMU when PVE 9 reports it.
    /// Columns that are not returned are hidden instead of being drawn as 0.
    private var memorySeries: [Series] {
        switch source {
        case .node:
            var series: [Series] = []
            if points.contains(.memoryTotal) {
                series.append(Series(name: String(localized: "总计"), color: .green, samples: points.samples(.memoryTotal)))
            }
            if points.contains(.memoryAvailable) {
                series.append(Series(name: String(localized: "可用"), color: .cyan, samples: points.samples(.memoryAvailable)))
            }
            if points.contains(.memoryUsed) {
                series.append(Series(name: String(localized: "已用"), color: .blue, samples: points.samples(.memoryUsed)))
            }
            // PVE writes arcsize = 0 on hosts without ZFS.
            if points.hasNonZero(.arcSize) {
                series.append(Series(name: String(localized: "ZFS ARC"), color: .orange, samples: points.samples(.arcSize)))
            }
            return series
        case .guest:
            return present([
                Series(name: String(localized: "总计"), color: .green, samples: points.samples(.memoryTotal)),
                Series(name: String(localized: "已用"), color: .blue, samples: points.samples(.memoryUsed)),
                Series(name: String(localized: "宿主占用"), color: .purple, samples: points.samples(.memoryHost)),
            ])
        }
    }

    private func present(_ series: [Series]) -> [Series] {
        series.filter { !$0.samples.isEmpty }
    }

    private func middleTime(_ metric: RRDMetric) -> Date? {
        let samples = points.samples(metric)
        guard !samples.isEmpty else { return nil }
        return samples[samples.count * 2 / 3].time
    }

    private func chartSection<Content: View>(_ title: LocalizedStringKey, id: String, @ViewBuilder content: () -> Content) -> some View {
        Section(title) {
            content()
                .frame(height: 200)
                .padding(.vertical, 6)
                .accessibilityIdentifier("chart-\(id)")
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
            if case .failed(let message) = failure, message == ErrorText.message(for: PVEError.cancelled) { return }
            error = failure
        }
    }
}

struct Series: Identifiable {
    var id: String { name }
    let name: String
    let color: Color
    let samples: [RRDSample]
}

enum ChartUnit {
    case percent, bytes, rate

    var scaleKind: NiceScale.Kind { self == .percent ? .fraction : .bytes }

    func axisLabel(_ value: Double, unitIndex: Int) -> String {
        switch self {
        case .percent:
            if value == 0 { return "0" }
            return value.formatted(.percent.precision(.fractionLength(0...1)))
        case .bytes:
            return ByteFormat.axisLabel(value, unitIndex: unitIndex)
        case .rate:
            return value == 0 ? "0" : ByteFormat.axisLabel(value, unitIndex: unitIndex) + "/s"
        }
    }

    func valueLabel(_ value: Double) -> String {
        switch self {
        case .percent: return Format.percent(value)
        case .bytes: return Format.bytes(value)
        case .rate: return Format.rate(value)
        }
    }
}

/// Values of every series at the selected time.
struct ChartSelection {
    struct Value: Identifiable {
        var id: String { name }
        let name: String
        let color: Color
        let time: Date
        let value: Double
    }

    let time: Date
    let values: [Value]

    init?(series: [Series], at date: Date) {
        var values: [Value] = []
        for series in series {
            guard let nearest = series.samples.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }) else { continue }
            values.append(Value(name: series.name, color: series.color, time: nearest.time, value: nearest.value))
        }
        guard let first = values.first else { return nil }
        // Snap the rule to the closest sample of the first series.
        time = first.time
        self.values = values
    }
}

/// Line chart with round Y ticks. Long press, then drag horizontally: a vertical rule and a
/// popover with the time and every series' value follow the finger; releasing hides them.
struct SeriesChart: View {
    let series: [Series]
    let unit: ChartUnit
    var timeframe: RRDTimeframe = .hour
    /// Demo / screenshot mode: a selection shown until the first gesture.
    var pinnedSelection: Date?

    @State private var selection: Date?

    var body: some View {
        let scale = NiceScale(maxValue: maxValue, kind: unit.scaleKind)
        let selected = selection.flatMap { ChartSelection(series: series, at: $0) }
        Chart {
            ForEach(series) { series in
                ForEach(series.samples) { sample in
                    LineMark(
                        x: .value("时间", sample.time),
                        y: .value("数值", sample.value),
                        series: .value("系列", series.name)
                    )
                    .foregroundStyle(by: .value("系列", series.name))
                    .interpolationMethod(.monotone)
                }
            }
            if let selected {
                RuleMark(x: .value("时间", selected.time))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(
                        position: .top,
                        spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        SelectionPopover(selection: selected, unit: unit, timeframe: timeframe)
                    }
                ForEach(selected.values) { value in
                    PointMark(x: .value("时间", value.time), y: .value("数值", value.value))
                        .foregroundStyle(value.color)
                        .symbolSize(36)
                }
            }
        }
        .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
        .chartYScale(domain: 0...scale.upperBound)
        .chartYAxis {
            AxisMarks(position: .leading, values: scale.ticks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(verbatim: unit.axisLabel(number, unitIndex: scale.unitIndex))
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartLegend(series.count > 1 ? .visible : .hidden)
        .chartXSelection(value: $selection)
        .chartGesture { proxy in
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .onChanged { value in
                    switch value {
                    case .first:
                        break
                    case .second(_, let drag):
                        if let drag {
                            proxy.selectXValue(at: drag.location.x)
                        }
                    }
                }
                .onEnded { _ in
                    selection = nil
                }
        }
        .onAppear {
            if let pinnedSelection { selection = pinnedSelection }
        }
        .sensoryFeedback(.selection, trigger: selected?.time)
    }

    private var maxValue: Double {
        series.flatMap(\.samples).map(\.value).max() ?? 0
    }
}

struct SelectionPopover: View {
    let selection: ChartSelection
    let unit: ChartUnit
    let timeframe: RRDTimeframe

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: timeText)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
            ForEach(selection.values) { value in
                HStack(spacing: 6) {
                    Circle()
                        .fill(value.color)
                        .frame(width: 7, height: 7)
                    Text(verbatim: value.name)
                    Spacer(minLength: 8)
                    Text(verbatim: unit.valueLabel(value.value))
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 140)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("chart-selection-popover")
    }

    private var timeText: String {
        switch timeframe {
        case .hour, .day:
            return selection.time.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())
        case .week, .month, .year:
            return selection.time.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour())
        }
    }
}
