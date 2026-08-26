import Charts
import SwiftData
import SwiftUI

enum MonitoringHistoryRange: String, CaseIterable, Identifiable {
    case day
    case week
    case month
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "24 小时"
        case .week: "7 天"
        case .month: "30 天"
        case .custom: "自定义"
        }
    }

    func dates(now: Date, customStart: Date, customEnd: Date) -> (Date, Date) {
        switch self {
        case .day: (now.addingTimeInterval(-24 * 60 * 60), now)
        case .week: (now.addingTimeInterval(-7 * 24 * 60 * 60), now)
        case .month: (now.addingTimeInterval(-30 * 24 * 60 * 60), now)
        case .custom: (min(customStart, customEnd), max(customStart, customEnd))
        }
    }
}

struct MonitoringHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let serverID: UUID
    let serverName: String
    @ObservedObject var runtime: ServerRuntimeState

    @State private var selectedMetric: MonitoringMetric = .cpuUsage
    @State private var selectedRange: MonitoringHistoryRange = .day
    @State private var customStart = Date().addingTimeInterval(-24 * 60 * 60)
    @State private var customEnd = Date()
    @State private var series: MonitoringHistorySeries?
    @State private var storageSummary: MonitoringStorageSummary?
    @State private var loadError: String?
    @State private var isLoading = true
    @State private var isCleaning = false
    @State private var showingCleanupConfirmation = false
    @State private var maintenanceReport: MonitoringMaintenanceReport?

    private var queryIdentity: String {
        [
            selectedMetric.rawValue,
            selectedRange.rawValue,
            String(customStart.timeIntervalSinceReferenceDate),
            String(customEnd.timeIntervalSinceReferenceDate),
            String(runtime.renderState.lastSuccessfulMonitorAt?.timeIntervalSinceReferenceDate ?? 0)
        ].joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                    controls
                    collectionStateBanner
                    historyContent
                    storageSection
                }
                .padding(AppleDesign.Spacing.lg)
                .frame(maxWidth: 1_100, alignment: .leading)
            }
            .navigationTitle("\(serverName) · 监控历史")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .task(id: queryIdentity) {
            await loadHistory()
        }
        .confirmationDialog(
            "执行历史保留策略？",
            isPresented: $showingCleanupConfirmation
        ) {
            Button("聚合并清理过期数据") {
                runMaintenance()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅清理超过 24 小时的原始值、30 天的 1 分钟聚合、1 年的 15 分钟聚合，或超过 512 MB 配额的最旧数据；活动缺口不会删除。")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack {
                Picker("指标", selection: $selectedMetric) {
                    ForEach(MonitoringMetric.allCases) { metric in
                        Text(metric.title).tag(metric)
                    }
                }
                .frame(maxWidth: 260)

                Picker("时间范围", selection: $selectedRange) {
                    ForEach(MonitoringHistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)
                Spacer()
            }
            if selectedRange == .custom {
                HStack {
                    DatePicker("开始", selection: $customStart)
                    DatePicker("结束", selection: $customEnd)
                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("历史查询条件")
    }

    @ViewBuilder
    private var collectionStateBanner: some View {
        if let historyError = appState.monitoringHistoryError {
            statusBanner(
                historyError,
                symbol: "externaldrive.badge.exclamationmark",
                color: Color.appError
            )
        } else if runtime.renderState.status == .failed {
            statusBanner(
                "当前实时采集失败；下方历史仍可离线查看，新的缺口会按原因保留。",
                symbol: "wifi.exclamationmark",
                color: Color.appWarning
            )
        } else if !runtime.renderState.isRefreshing && !runtime.renderState.hasSnapshot {
            statusBanner(
                "等待首次采集。历史为空时不会用 0 或旧值补线。",
                symbol: "clock",
                color: .secondary
            )
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        if isLoading {
            VStack(spacing: AppleDesign.Spacing.sm) {
                ProgressView()
                Text("正在读取本地历史")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 330)
            .applePanel()
        } else if let loadError {
            ContentUnavailableView {
                Label("无法读取监控历史", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("重试") { Task { await loadHistory() } }
            }
            .frame(maxWidth: .infinity, minHeight: 330)
            .applePanel()
        } else if let series, series.points.isEmpty {
            ContentUnavailableView {
                Label("此范围没有样本", systemImage: "chart.xyaxis.line")
            } description: {
                if series.gaps.isEmpty {
                    Text("尚未采集到该指标。旧值不会被延伸为连续数据。")
                } else {
                    Text("该范围只有 Data Gap，没有可绘制的有效样本。")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 330)
            .applePanel()
            gapList(series.gaps)
        } else if let series {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                HStack {
                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                        Text(series.metric.title)
                            .font(.headline)
                        Text(
                            "\(series.resolution.title) · " +
                            "\(DisplayFormat.integer(series.points.count)) 个绘制点"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !series.gaps.isEmpty {
                        Label(
                            "\(DisplayFormat.integer(series.gaps.count)) 个 Data Gap",
                            systemImage: "rectangle.split.3x1"
                        )
                            .font(.caption)
                            .foregroundStyle(Color.appWarning)
                    }
                }

                Chart {
                    ForEach(Array(series.segments.enumerated()), id: \.offset) { index, segment in
                        ForEach(segment) { point in
                            LineMark(
                                x: .value("时间", point.date),
                                y: .value(series.metric.title, point.average),
                                series: .value("连续片段", index)
                            )
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.linear)
                        }
                    }
                    ForEach(series.gaps) { gap in
                        RectangleMark(
                            xStart: .value("缺口开始", gap.start),
                            xEnd: .value("缺口结束", gap.end)
                        )
                        .foregroundStyle(
                            (gap.isCollectorSide ? Color.appWarning : Color.appError)
                                .opacity(0.13)
                        )
                    }
                }
                .chartLegend(.hidden)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6))
                }
                .frame(height: 300)
                .accessibilityLabel("\(series.metric.title)历史图表")
                .accessibilityValue(
                    "\(DisplayFormat.integer(series.points.count)) 个点，" +
                    "\(DisplayFormat.integer(series.gaps.count)) 个数据缺口"
                )
                Text("阴影区域为真实 Data Gap；折线按缺口拆分，不连接缺口前后的旧值。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .applePanel()
            gapList(series.gaps)
        }
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text("历史存储")
                        .font(.headline)
                    Text("原始值 24 小时 · 1 分钟聚合 30 天 · 15 分钟聚合 1 年")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("立即清理") {
                    showingCleanupConfirmation = true
                }
                .disabled(isCleaning)
            }
            if let storageSummary {
                ProgressView(value: storageSummary.quotaFraction)
                Text(
                    "估算占用 \(Self.byteString(storageSummary.estimatedBytes)) / \(Self.byteString(storageSummary.quotaBytes)) · " +
                    "原始帧 \(DisplayFormat.integer(storageSummary.rawSampleCount)) · " +
                    "聚合帧 \(DisplayFormat.integer(storageSummary.aggregateCount)) · " +
                    "缺口 \(DisplayFormat.integer(storageSummary.gapCount))"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if isCleaning {
                ProgressView("正在聚合并清理")
                    .controlSize(.small)
            } else if let maintenanceReport {
                Text(
                    "最近清理：原始帧 \(DisplayFormat.integer(maintenanceReport.rawSamplesRemoved))，" +
                    "聚合帧 \(DisplayFormat.integer(maintenanceReport.aggregatesRemoved))，" +
                    "缺口 \(DisplayFormat.integer(maintenanceReport.gapsRemoved))。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .applePanel()
    }

    private func gapList(_ gaps: [MonitoringGapInterval]) -> some View {
        Group {
            if !gaps.isEmpty {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
                    Text("Data Gap")
                        .font(.headline)
                    ForEach(gaps.prefix(20)) { gap in
                        HStack {
                            Image(systemName: gap.isCollectorSide ? "laptopcomputer.trianglebadge.exclamationmark" : "server.rack")
                                .foregroundStyle(gap.isCollectorSide ? Color.appWarning : Color.appError)
                            Text(gap.reason.title)
                            Spacer()
                            Text(
                                "\(gap.start.formatted(date: .abbreviated, time: .shortened)) – " +
                                gap.end.formatted(date: .omitted, time: .shortened)
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if gaps.count > 20 {
                        Text("另有 \(DisplayFormat.integer(gaps.count - 20)) 个缺口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .applePanel()
            }
        }
    }

    private func statusBanner(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(color)
            .padding(AppleDesign.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: AppleDesign.Radius.thumbnail))
    }

    @MainActor
    private func loadHistory() async {
        isLoading = true
        loadError = nil
        await Task.yield()
        guard !Task.isCancelled else { return }
        do {
            let repository = MonitoringHistoryRepository(context: modelContext)
            let now = Date()
            let dates = selectedRange.dates(
                now: now,
                customStart: customStart,
                customEnd: customEnd
            )
            let loaded = try repository.query(
                serverID: serverID,
                metric: selectedMetric,
                from: dates.0,
                to: dates.1,
                pixelWidth: 900
            )
            let summary = try repository.storageSummary()
            guard !Task.isCancelled else { return }
            series = loaded
            storageSummary = summary
        } catch {
            loadError = "本地历史查询失败（MON_HISTORY_QUERY）。"
        }
        isLoading = false
    }

    @MainActor
    private func runMaintenance() {
        isCleaning = true
        loadError = nil
        Task { @MainActor in
            await Task.yield()
            do {
                let repository = MonitoringHistoryRepository(context: modelContext)
                maintenanceReport = try repository.performMaintenance()
                storageSummary = try repository.storageSummary()
                await loadHistory()
            } catch {
                loadError = "历史清理失败；现有数据未被标记为已清理（MON_HISTORY_CLEANUP）。"
            }
            isCleaning = false
        }
    }

    private static func byteString(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}
