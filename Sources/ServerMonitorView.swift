import AppKit
import Charts
import SwiftUI

struct ServerMonitorLayoutView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var layoutStore: MonitorLayoutStore
    @AppStorage("hideIPInformation") private var hideIPInformation = false

    let server: ServerRecord
    @ObservedObject var runtime: ServerRuntimeState

    @State private var showingLayoutEditor = false
    @State private var showingHistory = false
    @State private var presentedDetail: MonitorCardKind?
    @State private var copiedMarkdown = false

    private var snapshot: ServerSnapshot { runtime.renderState.snapshot }
    private var history: [MetricPoint] { runtime.renderState.history }
    private var status: ServerConnectionStatus { runtime.renderState.status }
    private var cards: [MonitorCardKind] {
        layoutStore.visibleCards(
            for: server.id,
            snapshot: snapshot,
            hideIPInformation: hideIPInformation,
            disableLocationLookup: PrivacySettings.disableLocationLookup
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                monitorToolbar
                if let error = runtime.renderState.error, status == .failed {
                    errorBanner(error)
                } else if server.verificationStatus == .monitorUnsupported {
                    Label("SSH 可用，但当前主机不支持完整监控。终端和 SFTP 仍可使用。", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !server.enableDashboardMonitor {
                    Label("此服务器未加入仪表盘自动监控。", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !runtime.renderState.hasSnapshot {
                    VStack(spacing: AppleDesign.Spacing.sm) {
                        if runtime.renderState.isRefreshing || status == .connecting {
                            ProgressView()
                                .controlSize(.regular)
                        } else {
                            Image(systemName: "hourglass")
                                .font(.system(size: 28, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                        Text("等待首次资源采集")
                            .font(.headline)
                        Text(firstSnapshotDescription)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .applePanel()
                } else if cards.isEmpty {
                    ContentUnavailableView {
                        Label("没有可见卡片", systemImage: "rectangle.grid.2x2")
                    } description: {
                        Text("打开布局编辑器以恢复或显示监控卡片。")
                    } actions: {
                        Button("编辑布局") { showingLayoutEditor = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .applePanel()
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 330), spacing: AppleDesign.Spacing.md)],
                        alignment: .leading,
                        spacing: AppleDesign.Spacing.md
                    ) {
                        ForEach(cards) { card in
                            MonitorCardShell(
                                card: card,
                                onOpen: card.supportsDetail ? { presentedDetail = card } : nil,
                                onHide: {
                                    layoutStore.setHidden(true, card: card, for: server.id)
                                }
                            ) {
                                cardContent(card)
                            }
                        }
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: 1440, alignment: .leading)
        }
        .sheet(isPresented: $showingLayoutEditor) {
            MonitorLayoutEditorView(serverID: server.id, snapshot: snapshot)
                .environmentObject(layoutStore)
        }
        .sheet(isPresented: $showingHistory) {
            MonitoringHistoryView(
                serverID: server.id,
                serverName: server.displayName,
                runtime: runtime
            )
            .environmentObject(appState)
        }
        .overlay {
            if let card = presentedDetail {
                AppleDismissibleOverlay(
                    maxWidth: 1_000,
                    maxHeight: 760,
                    onDismiss: { presentedDetail = nil }
                ) {
                    MonitorCardDetailView(
                        card: card,
                        server: server,
                        snapshot: snapshot,
                        history: history,
                        onDismiss: {
                            presentedDetail = nil
                        }
                    )
                }
            }
        }
        .animation(reduceMotion ? nil : AppleDesign.quick, value: presentedDetail)
    }

    private var monitorToolbar: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                Text("服务器状态")
                    .font(.title2.weight(.bold))
                Text(monitorStatusText)
                .font(.caption)
                .foregroundStyle(
                    runtime.renderState.isStale(refreshInterval: appState.refreshInterval)
                        ? Color.appWarning
                        : .secondary
                )
            }
            Spacer()
            if copiedMarkdown {
                Label("已复制", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Color.appLive)
                    .transition(.opacity)
            }
            Button("编辑布局", systemImage: "rectangle.grid.2x2") {
                showingLayoutEditor = true
            }
            Button("历史", systemImage: "chart.xyaxis.line") {
                showingHistory = true
            }
            .help("查看持久化监控历史和 Data Gap")
            Menu {
                Button("复制 Markdown", systemImage: "doc.on.doc") {
                    copyMarkdown()
                }
                Toggle("隐藏 IP 信息", isOn: $hideIPInformation)
                Divider()
                Button("恢复默认布局", systemImage: "arrow.counterclockwise") {
                    layoutStore.reset(serverID: server.id)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("状态页操作")
        }
    }

    private var monitorStatusText: String {
        if snapshot.capturedAt == .distantPast {
            if server.verificationStatus == .monitorUnsupported {
                return "SSH 可用，但监控采集不受支持"
            }
            if !server.enableDashboardMonitor {
                return "未加入仪表盘自动监控"
            }
            return "等待首次采集"
        }
        var parts = ["更新于 \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))"]
        if let last = server.lastSuccessfulMonitorAt {
            parts.append("上次成功 \(last.formatted(date: .omitted, time: .standard))")
        }
        if server.lastLatencyMS > 0 {
            parts.append("延迟 \(Int(server.lastLatencyMS)) ms")
        }
        if let capabilities = runtime.renderState.capabilities {
            parts.append(capabilities.summary)
        }
        if runtime.renderState.isStale(refreshInterval: appState.refreshInterval) {
            parts.append("已过期")
        }
        return parts.joined(separator: " · ")
    }

    private var firstSnapshotDescription: String {
        if status == .failed {
            return "首次采集未完成。请检查上方错误后重试；空快照不会显示为资源读数。"
        }
        if server.verificationStatus == .monitorUnsupported {
            return "当前主机不支持完整监控，终端和 SFTP 仍可使用。"
        }
        if !server.enableDashboardMonitor {
            return "此服务器未启用自动监控，可使用上方刷新操作手动采集。"
        }
        return "正在准备监控数据，完成前不会显示占位的 0% 指标。"
    }

    @ViewBuilder
    private func cardContent(_ card: MonitorCardKind) -> some View {
        switch card {
        case .cpu:
            CPUMonitorCard(snapshot: snapshot, history: history)
        case .load:
            LoadMonitorCard(snapshot: snapshot, history: history)
        case .memory:
            MemoryMonitorCard(snapshot: snapshot)
        case .processes:
            ProcessesMonitorCard(snapshot: snapshot)
        case .network:
            NetworkMonitorCard(server: server, snapshot: snapshot, history: history)
        case .storage:
            StorageMonitorCard(server: server, snapshot: snapshot)
        case .gpu:
            GPUMonitorCard(snapshot: snapshot)
        case .location:
            LocationMonitorCard(
                server: server,
                snapshot: snapshot,
                allowsMapInteraction: false
            )
        case .docker:
            DockerMonitorCard(snapshot: snapshot)
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.appError)
            Text(error)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("重试") {
                Task { await appState.refresh(server) }
            }
        }
        .padding(AppleDesign.Spacing.md)
        .background(Color.appError.opacity(0.08))
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.thumbnail,
                style: .continuous
            )
        )
    }

    private func copyMarkdown() {
        let markdown = SnapshotMarkdownExporter.export(server: server, snapshot: snapshot)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        copiedMarkdown = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedMarkdown = false
        }
    }
}

private struct MonitorCardShell<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let card: MonitorCardKind
    let onOpen: (() -> Void)?
    let onHide: () -> Void
    @ViewBuilder let content: Content

    @State private var isHovering = false

    init(
        card: MonitorCardKind,
        onOpen: (() -> Void)?,
        onHide: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.card = card
        self.onOpen = onOpen
        self.onHide = onHide
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
            HStack(spacing: AppleDesign.Spacing.xs) {
                Image(systemName: card.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(card.title)
                    .font(.headline)
                Spacer()
                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Menu {
                    if let onOpen {
                        Button("打开详情", action: onOpen)
                    }
                    Button("隐藏卡片", systemImage: "eye.slash", action: onHide)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .applePanel(padding: AppleDesign.Spacing.md, radius: AppleDesign.Radius.card)
        .overlay {
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.card,
                style: .continuous
            )
            .stroke(
                isHovering && onOpen != nil
                    ? Color.appAccent.opacity(0.4)
                    : Color.clear,
                lineWidth: 1
            )
        }
        .contentShape(
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.card,
                style: .continuous
            )
        )
        .onTapGesture {
            onOpen?()
        }
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : AppleDesign.quick, value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(onOpen == nil ? [] : .isButton)
        .accessibilityHint(onOpen == nil ? "" : "打开\(card.title)详情")
    }
}

private struct CPUMonitorCard: View {
    let snapshot: ServerSnapshot
    let history: [MetricPoint]

    @State private var showsAllCores = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(DisplayFormat.percent(snapshot.cpuUsage))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .monospacedDigit()
                Spacer()
                if let temperature = snapshot.cpuTemperatureCelsius {
                    Label(
                        temperature.formatted(.number.precision(.fractionLength(1))) + "°C",
                        systemImage: "thermometer.medium"
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            Text(
                [snapshot.cpuModel, "\(snapshot.coreCount) 核"]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)

            Group {
                if showsAllCores, !snapshot.cpuCores.isEmpty {
                    CPUCoreBars(cores: snapshot.cpuCores)
                } else {
                    Chart(history.suffix(100)) { point in
                        AreaMark(
                            x: .value("时间", point.date),
                            y: .value("CPU", point.cpu)
                        )
                        .foregroundStyle(Color.appAccent.opacity(0.12))
                        LineMark(
                            x: .value("时间", point.date),
                            y: .value("CPU", point.cpu)
                        )
                        .foregroundStyle(Color.appAccent)
                        .interpolationMethod(.catmullRom)
                    }
                    .chartYScale(domain: 0...100)
                    .chartXAxis(.hidden)
                    .frame(height: 110)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard !snapshot.cpuCores.isEmpty else { return }
                showsAllCores.toggle()
            }
            .contextMenu {
                Button("显示总体") { showsAllCores = false }
                Button("显示所有核心") { showsAllCores = true }
                    .disabled(snapshot.cpuCores.isEmpty)
            }

            Text(showsAllCores ? "点击切换为总体历史" : "点击切换为每核心明细")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct CPUCoreBars: View {
    let cores: [CPUCoreMetric]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: AppleDesign.Spacing.xxs) {
                ForEach(cores) { core in
                    VStack(spacing: 3) {
                        GeometryReader { geometry in
                            VStack(spacing: 0) {
                                Spacer(minLength: 0)
                                segment(.appAccent, value: core.user, height: geometry.size.height)
                                segment(.appLive, value: core.system, height: geometry.size.height)
                                segment(.appWarning, value: core.nice, height: geometry.size.height)
                                segment(.secondary, value: core.ioWait, height: geometry.size.height)
                                segment(.appError, value: core.steal, height: geometry.size.height)
                            }
                            .background(Color.appTrack)
                            .clipShape(
                                RoundedRectangle(
                                    cornerRadius: AppleDesign.Radius.chip,
                                    style: .continuous
                                )
                            )
                        }
                        .frame(width: 14, height: 84)
                        Text("\(core.index)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("核心 \(core.index)")
                    .accessibilityValue(DisplayFormat.percent(core.usage))
                }
            }
        }
        .frame(height: 110)
    }

    private func segment(_ color: Color, value: Double, height: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(height: max(0, height * min(100, value) / 100))
    }
}

private struct LoadMonitorCard: View {
    let snapshot: ServerSnapshot
    let history: [MetricPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            Chart {
                ForEach(Array(history.suffix(100))) { point in
                    LineMark(x: .value("时间", point.date), y: .value("1 分钟", point.load1))
                        .foregroundStyle(Color.appAccent)
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("时间", point.date), y: .value("5 分钟", point.load5))
                        .foregroundStyle(Color.appLive)
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("时间", point.date), y: .value("15 分钟", point.load15))
                        .foregroundStyle(Color.appWarning)
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 130)
            HStack {
                LoadValue(title: "1 分钟", value: snapshot.load1, color: .appAccent)
                LoadValue(title: "5 分钟", value: snapshot.load5, color: .appLive)
                LoadValue(title: "15 分钟", value: snapshot.load15, color: .appWarning)
            }
        }
    }
}

private struct LoadValue: View {
    let title: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
            HStack(spacing: AppleDesign.Spacing.xxs) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value.formatted(.number.precision(.fractionLength(2))))
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MemoryMonitorCard: View {
    let snapshot: ServerSnapshot

    private var breakdown: MemoryBreakdown {
        MonitorPresentation.memoryBreakdown(snapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text(DisplayFormat.percent(snapshot.memoryUsage))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .monospacedDigit()
                    Text(
                        "\(DisplayFormat.bytes(snapshot.memoryUsedBytes)) / \(DisplayFormat.bytes(snapshot.memoryTotalBytes))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "memorychip")
                    .font(.title2)
                    .foregroundStyle(MonitorSeverity.percentage(snapshot.memoryUsage).color)
                    .frame(width: 44, height: 44)
                    .background(
                        MonitorSeverity.percentage(snapshot.memoryUsage).color.opacity(0.1)
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: AppleDesign.Radius.thumbnail,
                            style: .continuous
                        )
                    )
            }

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    memorySegment(
                        value: breakdown.used,
                        total: snapshot.memoryTotalBytes,
                        width: geometry.size.width,
                        color: .appAccent
                    )
                    memorySegment(
                        value: breakdown.cached + breakdown.buffers,
                        total: snapshot.memoryTotalBytes,
                        width: geometry.size.width,
                        color: .appWarning
                    )
                    Spacer(minLength: 0)
                }
                .background(Color.appTrack)
                .clipShape(Capsule())
            }
            .frame(height: 10)

            HStack {
                compactMemoryValue("已用", value: breakdown.used, color: .appAccent)
                Spacer()
                compactMemoryValue(
                    "缓存",
                    value: breakdown.cached + breakdown.buffers,
                    color: .appWarning
                )
                Spacer()
                compactMemoryValue("空闲", value: breakdown.free, color: .appLive)
            }

            Divider()

            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
                HStack {
                    Text("Swap").font(.callout.weight(.semibold))
                    Spacer()
                    Text(
                        snapshot.swapTotalBytes > 0
                            ? "\(DisplayFormat.bytes(snapshot.swapUsedBytes)) / \(DisplayFormat.bytes(snapshot.swapTotalBytes))"
                            : "N/A"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                MonitorLinearGauge(value: snapshot.swapUsage, tint: .appWarning)
            }
        }
    }

    private func memorySegment(
        value: Double,
        total: Double,
        width: CGFloat,
        color: Color
    ) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: total > 0 ? width * min(1, max(0, value / total)) : 0)
    }

    private func compactMemoryValue(
        _ title: String,
        value: Double,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: AppleDesign.Spacing.xxs) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title).foregroundStyle(.secondary)
            }
            Text(DisplayFormat.bytes(value))
                .monospacedDigit()
        }
        .font(.caption)
    }
}

private struct ProcessesMonitorCard: View {
    let snapshot: ServerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack {
                Label("\(snapshot.processCount) 个进程", systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.semibold))
                Spacer()
                Label("\(snapshot.loggedInUsers)", systemImage: "person.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if snapshot.topProcesses.isEmpty {
                ContentUnavailableView {
                    Label("等待进程数据", systemImage: "list.bullet.rectangle")
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ForEach(snapshot.topProcesses.prefix(4)) { process in
                    ProcessUsageRow(process: process)
                }
            }
        }
    }
}

private struct ProcessUsageRow: View {
    let process: ProcessMetric

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(process.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(process.user.isEmpty ? "PID \(process.pid)" : "\(process.user) · PID \(process.pid)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("CPU \(process.cpu.formatted(.number.precision(.fractionLength(1))))%")
                    .foregroundStyle(
                        MonitorSeverity.percentage(process.cpu).color
                    )
                Text("MEM \(process.memory.formatted(.number.precision(.fractionLength(1))))%")
                    .foregroundStyle(.secondary)
            }
            .font(.caption.monospacedDigit())
            HStack(spacing: AppleDesign.Spacing.xxs) {
                MonitorLinearGauge(value: process.cpu)
                MonitorLinearGauge(value: process.memory, tint: .appWarning)
            }
        }
        .padding(.vertical, AppleDesign.Spacing.xxs)
    }
}

private struct NetworkMonitorCard: View {
    @AppStorage("networkDisplayInBits") private var displayInBits = false

    let server: ServerRecord
    let snapshot: ServerSnapshot
    let history: [MetricPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text(snapshot.activeNetworkInterface.isEmpty ? "自动选择接口" : snapshot.activeNetworkInterface)
                        .font(.headline)
                    Text("活动接口")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "network")
                    .font(.title2)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 42, height: 42)
                    .background(Color.appAccent.opacity(0.1))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: AppleDesign.Radius.thumbnail,
                            style: .continuous
                        )
                    )
            }

            HStack(spacing: AppleDesign.Spacing.lg) {
                NetworkCardValue(
                    title: "下载",
                    value: NetworkFormat.speed(
                        snapshot.downloadBytesPerSecond,
                        bits: displayInBits
                    ),
                    symbol: "arrow.down",
                    color: .appAccent
                )
                NetworkCardValue(
                    title: "上传",
                    value: NetworkFormat.speed(
                        snapshot.uploadBytesPerSecond,
                        bits: displayInBits
                    ),
                    symbol: "arrow.up",
                    color: .appLive
                )
            }

            Chart(Array(history.suffix(40))) { point in
                AreaMark(
                    x: .value("时间", point.date),
                    y: .value("下载", point.download)
                )
                .foregroundStyle(Color.appAccent.opacity(0.1))
                LineMark(
                    x: .value("时间", point.date),
                    y: .value("下载", point.download)
                )
                .foregroundStyle(Color.appAccent)
                LineMark(
                    x: .value("时间", point.date),
                    y: .value("上传", point.upload)
                )
                .foregroundStyle(Color.appLive)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 76)

            Divider()
            HStack {
                Text("累计")
                Spacer()
                Text(
                    "↓ \(NetworkFormat.bytes(snapshot.networkReceivedBytes, bits: displayInBits))  ↑ \(NetworkFormat.bytes(snapshot.networkSentBytes, bits: displayInBits))"
                )
                .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct NetworkCardValue: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(color.opacity(0.1))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StorageMonitorCard: View {
    let server: ServerRecord
    let snapshot: ServerSnapshot

    private var filesystems: [FilesystemMetric] {
        MonitorPresentation.orderedFilesystems(
            snapshot.filesystems,
            pinnedMountPoint: UserDefaults.standard.string(
                forKey: "defaultVolume.\(server.id.uuidString)"
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            if let primary = filesystems.first {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(primary.mountPoint)
                                .font(.headline.monospaced())
                                .lineLimit(1)
                            Text("\(primary.device) · \(primary.filesystemType)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(DisplayFormat.percent(primary.usage))
                            .font(.title3.monospacedDigit().weight(.bold))
                            .foregroundStyle(
                                MonitorSeverity.percentage(primary.usage).color
                            )
                    }
                    MonitorLinearGauge(value: primary.usage)
                    Text(
                        "\(DisplayFormat.bytes(primary.usedBytes)) / \(DisplayFormat.bytes(primary.totalBytes))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            if filesystems.count > 1 {
                Divider()
                ForEach(filesystems.dropFirst().prefix(2)) { filesystem in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(filesystem.mountPoint)
                                .font(.callout.monospaced().weight(.medium))
                                .lineLimit(1)
                            Text(DisplayFormat.bytes(filesystem.totalBytes))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(DisplayFormat.percent(filesystem.usage))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(
                                MonitorSeverity.percentage(filesystem.usage).color
                            )
                    }
                }
            }

            if filesystems.isEmpty {
                ContentUnavailableView {
                    Label("等待文件系统数据", systemImage: "internaldrive")
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
    }
}

private struct GPUMonitorCard: View {
    let snapshot: ServerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack {
                Label("\(snapshot.gpus.count) 个 GPU", systemImage: "display")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(
                    [snapshot.gpuDriverVersion.isEmpty ? nil : "Driver \(snapshot.gpuDriverVersion)",
                     snapshot.cudaVersion.isEmpty ? nil : "CUDA \(snapshot.cudaVersion)"]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            ForEach(snapshot.gpus.prefix(2)) { gpu in
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
                    HStack {
                        Text("GPU \(gpu.index) · \(gpu.name)")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Spacer()
                        if let temperature = gpu.temperatureCelsius {
                            Text("\(temperature.formatted(.number.precision(.fractionLength(0))))°C")
                                .monospacedDigit()
                                .foregroundStyle(
                                    temperature >= 85 ? Color.appError : Color.secondary
                                )
                        }
                    }
                    HStack {
                        Text("利用率")
                        Spacer()
                        Text(DisplayFormat.percent(gpu.utilization))
                            .fontWeight(.semibold)
                    }
                    .font(.caption.monospacedDigit())
                    MonitorLinearGauge(value: gpu.utilization)
                    HStack {
                        let memoryUsage = gpu.memoryTotalBytes > 0
                            ? gpu.memoryUsedBytes / gpu.memoryTotalBytes * 100
                            : 0
                        Text("显存 \(DisplayFormat.percent(memoryUsage))")
                        Spacer()
                        if let power = gpu.powerWatts {
                            Text("\(power.formatted(.number.precision(.fractionLength(1)))) W")
                        } else {
                            Text(DisplayFormat.bytes(gpu.memoryTotalBytes))
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                if gpu.id != snapshot.gpus.prefix(2).last?.id {
                    Divider()
                }
            }
        }
    }
}

private struct LocationMonitorCard: View {
    let server: ServerRecord
    let snapshot: ServerSnapshot
    let allowsMapInteraction: Bool

    var body: some View {
        ServerLocationMapView(
            server: server,
            initialLocation: snapshot.geoLocation,
            allowsInteraction: allowsMapInteraction
        )
    }
}

private struct DockerMonitorCard: View {
    let snapshot: ServerSnapshot

    private var summary: DockerStatusSummary {
        MonitorPresentation.dockerSummary(snapshot.dockerContainers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text("Docker \(snapshot.dockerVersion)")
                        .font(.headline)
                    Text("\(summary.total) 个容器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "shippingbox.fill")
                    .font(.title)
                    .foregroundStyle(Color.appAccent)
            }

            HStack(spacing: AppleDesign.Spacing.sm) {
                DockerCountBadge(
                    title: "运行中",
                    value: summary.running,
                    color: .appLive
                )
                DockerCountBadge(
                    title: "已停止",
                    value: summary.stopped,
                    color: .secondary
                )
                if summary.other > 0 {
                    DockerCountBadge(
                        title: "其他",
                        value: summary.other,
                        color: .appWarning
                    )
                }
            }

            ForEach(snapshot.dockerContainers.prefix(4)) { container in
                HStack {
                    StatusDot(
                        status: container.state.lowercased() == "running" ? .online : .offline
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(container.name).font(.callout.weight(.medium))
                        Text(container.image)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(container.state)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DockerCountBadge: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.xxs) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(value)")
                .font(.caption.monospacedDigit().weight(.bold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, AppleDesign.Spacing.xs)
        .padding(.vertical, AppleDesign.Spacing.xxs)
        .background(color.opacity(0.08))
        .clipShape(Capsule())
    }
}

struct MonitorLayoutEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var layoutStore: MonitorLayoutStore

    let serverID: UUID
    let snapshot: ServerSnapshot

    @State private var order: [MonitorCardKind] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text("编辑状态卡布局")
                        .font(.title2.weight(.bold))
                    Text("拖动排序，或隐藏不需要的卡片。GPU 与 Docker 会在不可用时自动隐藏。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(AppleDesign.Spacing.lg)
            Divider()
            List {
                ForEach(order) { card in
                    HStack {
                        Image(systemName: card.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title)
                            if !card.isAvailable(in: snapshot, hideIPInformation: false) {
                                Text("当前服务器不可用，将自动隐藏")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        HStack(spacing: AppleDesign.Spacing.xxs) {
                            Button {
                                move(card, offset: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .disabled(order.first == card)
                            Button {
                                move(card, offset: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .disabled(order.last == card)
                        }
                        .buttonStyle(.borderless)
                        Toggle(
                            "显示",
                            isOn: Binding(
                                get: { !layoutStore.isHidden(card, for: serverID) },
                                set: {
                                    layoutStore.setHidden(!$0, card: card, for: serverID)
                                }
                            )
                        )
                        .labelsHidden()
                    }
                    .frame(minHeight: 44)
                }
                .onMove { offsets, destination in
                    order.move(fromOffsets: offsets, toOffset: destination)
                    layoutStore.setOrder(order, for: serverID)
                }
            }
            Divider()
            HStack {
                Button("恢复默认布局", systemImage: "arrow.counterclockwise") {
                    layoutStore.reset(serverID: serverID)
                    order = layoutStore.orderedCards(for: serverID)
                }
                Spacer()
            }
            .padding(AppleDesign.Spacing.md)
        }
        .frame(width: 560, height: 620)
        .task {
            order = layoutStore.orderedCards(for: serverID)
        }
    }

    private func move(_ card: MonitorCardKind, offset: Int) {
        guard let index = order.firstIndex(of: card) else { return }
        let destination = index + offset
        guard order.indices.contains(destination) else { return }
        order.swapAt(index, destination)
        layoutStore.setOrder(order, for: serverID)
    }
}

private struct MonitorCardDetailView: View {
    let card: MonitorCardKind
    let server: ServerRecord
    let snapshot: ServerSnapshot
    let history: [MetricPoint]
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(card.title, systemImage: card.symbol)
                    .font(.title2.weight(.bold))
                Spacer()
                Button("完成", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AppleDesign.Spacing.lg)
            Divider()
            detailContent
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch card {
        case .cpu:
            CPUDetailView(snapshot: snapshot, history: history)
        case .load:
            LoadMonitorCard(snapshot: snapshot, history: history)
                .padding(AppleDesign.Spacing.lg)
        case .memory:
            MemoryDashboardDetailView(snapshot: snapshot, history: history)
        case .processes:
            ProcessDashboardDetailView(snapshot: snapshot)
        case .network:
            NetworkDashboardDetailView(
                server: server,
                snapshot: snapshot,
                history: history
            )
        case .storage:
            StorageDashboardDetailView(server: server, snapshot: snapshot)
        case .gpu:
            GPUDashboardDetailView(snapshot: snapshot)
        case .docker:
            DockerDashboardDetailView(snapshot: snapshot)
        case .location:
            LocationMonitorCard(
                server: server,
                snapshot: snapshot,
                allowsMapInteraction: true
            )
                .padding(AppleDesign.Spacing.lg)
        }
    }
}

private struct CPUDetailView: View {
    let snapshot: ServerSnapshot
    let history: [MetricPoint]

    private var usageTint: Color {
        if snapshot.cpuUsage >= 90 { return .appError }
        if snapshot.cpuUsage >= 75 { return .appWarning }
        return .appAccent
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                overviewPanel
                trendPanel
                corePanel
            }
            .padding(AppleDesign.Spacing.lg)
        }
    }

    private var overviewPanel: some View {
        HStack(spacing: AppleDesign.Spacing.lg) {
            ZStack {
                Circle()
                    .stroke(Color.appTrack, lineWidth: 12)
                Circle()
                    .trim(from: 0, to: min(1, max(0, snapshot.cpuUsage / 100)))
                    .stroke(
                        usageTint,
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                VStack(spacing: AppleDesign.Spacing.xxs) {
                    Text(DisplayFormat.percent(snapshot.cpuUsage))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("总体使用率")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 132, height: 132)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("CPU 总体使用率")
            .accessibilityValue(DisplayFormat.percent(snapshot.cpuUsage))

            Divider()
                .frame(height: 120)

            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text("处理器")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(snapshot.cpuModel.isEmpty ? "未识别处理器型号" : snapshot.cpuModel)
                        .font(.headline)
                        .lineLimit(2)
                }

                HStack(spacing: AppleDesign.Spacing.lg) {
                    CPUDetailFact(
                        title: "逻辑核心",
                        value: "\(snapshot.coreCount)",
                        symbol: "cpu"
                    )
                    CPUDetailFact(
                        title: "1 分钟负载",
                        value: snapshot.load1.formatted(
                            .number.precision(.fractionLength(2))
                        ),
                        symbol: "waveform.path.ecg"
                    )
                    CPUDetailFact(
                        title: "温度",
                        value: snapshot.cpuTemperatureCelsius.map {
                            $0.formatted(.number.precision(.fractionLength(1))) + "°C"
                        } ?? "—",
                        symbol: "thermometer.medium"
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .applePanel(padding: AppleDesign.Spacing.lg, radius: AppleDesign.Radius.card)
    }

    private var trendPanel: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text("使用率趋势")
                        .font(.headline)
                    Text("最近 \(min(history.count, 120)) 个采样点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: AppleDesign.Spacing.md) {
                    CPUTrendValue(title: "1 分钟", value: snapshot.load1)
                    CPUTrendValue(title: "5 分钟", value: snapshot.load5)
                    CPUTrendValue(title: "15 分钟", value: snapshot.load15)
                }
            }

            if history.isEmpty {
                ContentUnavailableView {
                    Label("等待趋势数据", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("完成至少一次刷新后开始绘制 CPU 趋势。")
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                Chart(Array(history.suffix(120))) { point in
                    AreaMark(
                        x: .value("时间", point.date),
                        y: .value("CPU", point.cpu)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.appAccent.opacity(0.28),
                                Color.appAccent.opacity(0.02)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("CPU", point.cpu)
                    )
                    .foregroundStyle(Color.appAccent)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let percentage = value.as(Int.self) {
                                Text("\(percentage)%")
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 210)
            }
        }
        .applePanel(padding: AppleDesign.Spacing.lg, radius: AppleDesign.Radius.card)
    }

    private var corePanel: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text("每核心明细")
                        .font(.headline)
                    Text("实时展示各核心的运行时间构成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CPUCoreLegend()
            }

            if snapshot.cpuCores.isEmpty {
                ContentUnavailableView {
                    Label("没有每核心数据", systemImage: "cpu")
                } description: {
                    Text("当前系统未返回 /proc/stat 的每核心采样。")
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(minimum: 210, maximum: 300),
                            spacing: AppleDesign.Spacing.sm
                        )
                    ],
                    alignment: .leading,
                    spacing: AppleDesign.Spacing.sm
                ) {
                    ForEach(snapshot.cpuCores) { core in
                        CPUCoreDetailTile(core: core)
                    }
                }
            }
        }
        .applePanel(padding: AppleDesign.Spacing.lg, radius: AppleDesign.Radius.card)
    }
}

private struct CPUDetailFact: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(Color.appAccent)
                .frame(width: 24, height: 24)
                .background(Color.appAccent.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: AppleDesign.Radius.chip))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
        }
    }
}

private struct CPUTrendValue: View {
    let title: String
    let value: Double

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.formatted(.number.precision(.fractionLength(2))))
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }
}

private struct CPUCoreLegend: View {
    var body: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            legendItem("User", color: .appAccent)
            legendItem("System", color: .appLive)
            legendItem("Nice", color: .appWarning)
            legendItem("IOWait", color: .secondary)
            legendItem("Steal", color: .appError)
        }
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: AppleDesign.Spacing.xxs) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CPUCoreDetailTile: View {
    let core: CPUCoreMetric

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
            HStack {
                Text("核心 \(core.index)")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(DisplayFormat.percent(core.usage))
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(core.usage >= 90 ? Color.appError : Color.primary)
            }

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    segment(.appAccent, value: core.user, width: geometry.size.width)
                    segment(.appLive, value: core.system, width: geometry.size.width)
                    segment(.appWarning, value: core.nice, width: geometry.size.width)
                    segment(.secondary, value: core.ioWait, width: geometry.size.width)
                    segment(.appError, value: core.steal, width: geometry.size.width)
                    Spacer(minLength: 0)
                }
                .background(Color.appTrack)
                .clipShape(Capsule())
            }
            .frame(height: 8)

            HStack {
                detailValue("User", value: core.user)
                Spacer()
                detailValue("System", value: core.system)
                Spacer()
                detailValue("IO", value: core.ioWait)
            }
        }
        .padding(AppleDesign.Spacing.sm)
        .background(Color.appHover)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.thumbnail,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.thumbnail,
                style: .continuous
            )
            .stroke(Color.appHairline.opacity(0.35))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("核心 \(core.index)")
        .accessibilityValue(DisplayFormat.percent(core.usage))
    }

    private func segment(_ color: Color, value: Double, width: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, width * min(100, value) / 100))
    }

    private func detailValue(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(DisplayFormat.percent(value))
                .font(.caption.monospacedDigit())
        }
    }
}

private enum ProcessSortField: String, CaseIterable, Identifiable {
    case cpu, memory, pid, name, user, threads, arguments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "内存"
        case .pid: "PID"
        case .name: "名称"
        case .user: "用户"
        case .threads: "线程"
        case .arguments: "参数"
        }
    }
}

private struct ProcessDetailView: View {
    let processes: [ProcessMetric]

    @State private var searchText = ""
    @State private var sortField: ProcessSortField = .cpu
    @State private var descending = true

    private var rows: [ProcessMetric] {
        let filtered = processes.filter {
            searchText.isEmpty ||
            String($0.pid).localizedCaseInsensitiveContains(searchText) ||
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.user.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortField {
            case .cpu: comparison = compare(lhs.cpu, rhs.cpu)
            case .memory: comparison = compare(lhs.memory, rhs.memory)
            case .pid: comparison = compare(lhs.pid, rhs.pid)
            case .name: comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .user: comparison = lhs.user.localizedStandardCompare(rhs.user)
            case .threads: comparison = compare(lhs.threadCount, rhs.threadCount)
            case .arguments:
                comparison = lhs.arguments.localizedStandardCompare(rhs.arguments)
            }
            return descending
                ? comparison == .orderedDescending
                : comparison == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("搜索 PID、进程名称或用户", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                Picker("排序", selection: $sortField) {
                    ForEach(ProcessSortField.allCases) { field in
                        Text(field.title).tag(field)
                    }
                }
                Button {
                    descending.toggle()
                } label: {
                    Image(systemName: descending ? "arrow.down" : "arrow.up")
                }
                .help(descending ? "降序" : "升序")
            }
            .padding(AppleDesign.Spacing.md)
            Table(rows) {
                TableColumn("PID") { Text("\($0.pid)").monospacedDigit() }.width(65)
                TableColumn("名称") { Text($0.name).fontWeight(.medium) }.width(min: 100, ideal: 140)
                TableColumn("用户") { Text($0.user) }.width(min: 80, ideal: 110)
                TableColumn("CPU%") {
                    Text($0.cpu.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
                }.width(65)
                TableColumn("内存%") {
                    Text($0.memory.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
                }.width(70)
                TableColumn("线程") { Text("\($0.threadCount)").monospacedDigit() }.width(55)
                TableColumn("参数") { Text($0.arguments).font(.caption.monospaced()).lineLimit(1) }
            }
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

private enum NetworkDetailMode: String, CaseIterable, Identifiable {
    case live
    case vnStat
    var id: String { rawValue }
    var title: String { self == .live ? "实时" : "vnStat" }
}

private struct NetworkDetailView: View {
    @AppStorage("networkDisplayInBits") private var displayInBits = false

    let server: ServerRecord
    let snapshot: ServerSnapshot
    let history: [MetricPoint]

    @State private var mode: NetworkDetailMode = .live
    @State private var period: VnStatPeriod = .daily
    @State private var selectedInterface = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("视图", selection: $mode) {
                    ForEach(NetworkDetailMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                Picker("默认网络接口", selection: $selectedInterface) {
                    ForEach(snapshot.networkInterfaces) { interface in
                        Text(interface.name).tag(interface.name)
                    }
                }
                .frame(width: 210)
                .onChange(of: selectedInterface) {
                    UserDefaults.standard.set(
                        selectedInterface,
                        forKey: "defaultNetworkInterface.\(server.id.uuidString)"
                    )
                }
            }
            .padding(AppleDesign.Spacing.md)
            Divider()
            if mode == .live {
                liveContent
            } else {
                vnStatContent
            }
        }
        .task {
            selectedInterface = UserDefaults.standard.string(
                forKey: "defaultNetworkInterface.\(server.id.uuidString)"
            ) ?? snapshot.activeNetworkInterface
        }
    }

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
            Chart {
                ForEach(Array(history.suffix(100))) { point in
                    LineMark(x: .value("时间", point.date), y: .value("下载", point.download))
                        .foregroundStyle(Color.appAccent)
                    LineMark(x: .value("时间", point.date), y: .value("上传", point.upload))
                        .foregroundStyle(Color.appLive)
                }
            }
            .frame(height: 220)
            Table(snapshot.networkInterfaces) {
                TableColumn("接口") { Text($0.name).font(.body.monospaced()) }
                TableColumn("下载") {
                    Text(NetworkFormat.speed($0.downloadBytesPerSecond, bits: displayInBits))
                        .monospacedDigit()
                }
                TableColumn("上传") {
                    Text(NetworkFormat.speed($0.uploadBytesPerSecond, bits: displayInBits))
                        .monospacedDigit()
                }
                TableColumn("累计接收") {
                    Text(NetworkFormat.bytes($0.receivedBytes, bits: displayInBits)).monospacedDigit()
                }
                TableColumn("累计发送") {
                    Text(NetworkFormat.bytes($0.sentBytes, bits: displayInBits)).monospacedDigit()
                }
            }
            .frame(minHeight: 220)
        }
        .padding(AppleDesign.Spacing.lg)
    }

    @ViewBuilder
    private var vnStatContent: some View {
        if !snapshot.vnStatAvailable {
            VStack(spacing: AppleDesign.Spacing.md) {
                ContentUnavailableView {
                    Label("未安装 vnStat", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("vnStat 在服务器上长期记录网络流量，安装后需要等待一段时间收集数据。")
                } actions: {
                    Link("查看 vnStat 安装说明", destination: URL(string: "https://humdi.net/vnstat/")!)
                }
                DemoVnStatChart()
                    .frame(height: 180)
                    .padding(.horizontal, AppleDesign.Spacing.lg)
            }
        } else if snapshot.vnStatCollecting {
            ContentUnavailableView {
                Label("vnStat 正在收集数据", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("刚安装后需要一点时间，稍后刷新即可看到历史图表。")
            }
        } else {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                HStack {
                    Picker("周期", selection: $period) {
                        ForEach(VnStatPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Spacer()
                    Text("来源：\(snapshot.vnStatSource)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VnStatChart(
                    points: snapshot.vnStatHistory.filter { $0.period == period },
                    displayInBits: displayInBits
                )
            }
            .padding(AppleDesign.Spacing.lg)
        }
    }
}

private struct VnStatChart: View {
    let points: [VnStatTrafficPoint]
    let displayInBits: Bool

    var body: some View {
        Chart(points) { point in
            BarMark(
                x: .value("时间", point.date),
                y: .value("下载", displayInBits ? point.receivedBytes * 8 : point.receivedBytes)
            )
            .foregroundStyle(Color.appAccent)
            BarMark(
                x: .value("时间", point.date),
                y: .value("上传", displayInBits ? point.sentBytes * 8 : point.sentBytes)
            )
            .foregroundStyle(Color.appLive)
        }
        .frame(minHeight: 300)
    }
}

private struct DemoVnStatChart: View {
    private let values = [24.0, 38, 30, 62, 54, 72, 48]

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            BarMark(x: .value("天", index), y: .value("流量", value))
                .foregroundStyle(Color.appAccent.opacity(0.55))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .overlay(alignment: .topLeading) {
            Text("安装后的历史图表示例")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StorageDetailView: View {
    let server: ServerRecord
    let snapshot: ServerSnapshot

    @State private var selectedVolume = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文件系统与设备 I/O")
                    .font(.headline)
                Spacer()
                Picker("默认卷", selection: $selectedVolume) {
                    ForEach(snapshot.filesystems) { filesystem in
                        Text(filesystem.mountPoint).tag(filesystem.mountPoint)
                    }
                }
                .frame(width: 220)
                .onChange(of: selectedVolume) {
                    UserDefaults.standard.set(
                        selectedVolume,
                        forKey: "defaultVolume.\(server.id.uuidString)"
                    )
                }
            }
            .padding(AppleDesign.Spacing.md)
            Divider()
            Table(snapshot.filesystems) {
                TableColumn("挂载点") { Text($0.mountPoint).font(.body.monospaced()) }
                TableColumn("文件系统") { Text($0.filesystemType) }.width(90)
                TableColumn("已用") { Text(DisplayFormat.bytes($0.usedBytes)).monospacedDigit() }
                TableColumn("总量") { Text(DisplayFormat.bytes($0.totalBytes)).monospacedDigit() }
                TableColumn("使用率") { Text(DisplayFormat.percent($0.usage)).monospacedDigit() }
            }
            .frame(minHeight: 230)
            Divider()
            Table(snapshot.diskIO) {
                TableColumn("设备") { Text($0.device).font(.body.monospaced()) }
                TableColumn("读取") { Text(DisplayFormat.speed($0.readBytesPerSecond)).monospacedDigit() }
                TableColumn("写入") { Text(DisplayFormat.speed($0.writeBytesPerSecond)).monospacedDigit() }
                TableColumn("读 IOPS") { Text($0.readIOPS.formatted(.number.precision(.fractionLength(1)))).monospacedDigit() }
                TableColumn("写 IOPS") { Text($0.writeIOPS.formatted(.number.precision(.fractionLength(1)))).monospacedDigit() }
                TableColumn("读延迟") { Text("\($0.readLatencyMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms").monospacedDigit() }
                TableColumn("写延迟") { Text("\($0.writeLatencyMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms").monospacedDigit() }
                TableColumn("总读取") { Text(DisplayFormat.bytes($0.lifetimeReadBytes)).monospacedDigit() }
                TableColumn("总写入") { Text(DisplayFormat.bytes($0.lifetimeWriteBytes)).monospacedDigit() }
            }
            .frame(minHeight: 220)
        }
        .task {
            selectedVolume = UserDefaults.standard.string(
                forKey: "defaultVolume.\(server.id.uuidString)"
            ) ?? snapshot.filesystems.first(where: { $0.mountPoint == "/" })?.mountPoint ?? ""
        }
    }
}

private struct GPUDetailView: View {
    let snapshot: ServerSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                ForEach(snapshot.gpus) { gpu in
                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                        HStack {
                            Text("GPU \(gpu.index) · \(gpu.name)")
                                .font(.headline)
                            Spacer()
                            if let temperature = gpu.temperatureCelsius {
                                Text("\(temperature.formatted(.number.precision(.fractionLength(0))))°C")
                                    .monospacedDigit()
                            }
                        }
                        ProgressView(value: gpu.utilization / 100).tint(.appAccent)
                        LabeledContent("利用率", value: DisplayFormat.percent(gpu.utilization))
                        LabeledContent(
                            "显存可用",
                            value: "\(DisplayFormat.bytes(max(0, gpu.memoryTotalBytes - gpu.memoryUsedBytes))) / \(DisplayFormat.bytes(gpu.memoryTotalBytes))"
                        )
                        if let fan = gpu.fanPercent {
                            LabeledContent("风扇", value: DisplayFormat.percent(fan))
                        }
                        if let power = gpu.powerWatts, let limit = gpu.powerLimitWatts {
                            LabeledContent(
                                "功耗",
                                value: "\(power.formatted(.number.precision(.fractionLength(1)))) / \(limit.formatted(.number.precision(.fractionLength(1)))) W"
                            )
                        }
                        let processes = snapshot.gpuProcesses.filter { $0.gpuID == gpu.uuid }
                        if !processes.isEmpty {
                            Divider()
                            ForEach(processes) { process in
                                HStack {
                                    Text("\(process.pid)").font(.caption.monospaced())
                                    Text(process.name).lineLimit(1)
                                    Spacer()
                                    Text(DisplayFormat.bytes(process.memoryBytes)).monospacedDigit()
                                }
                            }
                        }
                    }
                    .applePanel()
                }
            }
            .padding(AppleDesign.Spacing.lg)
        }
    }
}

private struct DockerDetailView: View {
    let snapshot: ServerSnapshot

    var body: some View {
        Table(snapshot.dockerContainers) {
            TableColumn("名称") { Text($0.name).fontWeight(.medium) }
            TableColumn("镜像") { Text($0.image) }
            TableColumn("状态") { container in
                Label(
                    container.state,
                    systemImage: container.state.lowercased() == "running"
                        ? "checkmark.circle.fill"
                        : "stop.circle"
                )
                .foregroundStyle(
                    container.state.lowercased() == "running"
                        ? Color.appLive
                        : Color.secondary
                )
            }
            TableColumn("详情") { Text($0.status).foregroundStyle(.secondary) }
        }
    }
}

enum SnapshotMarkdownExporter {
    static func export(server: ServerRecord, snapshot: ServerSnapshot) -> String {
        var lines = [
            "# \(server.name)",
            "",
            "- Host: `\(server.username)@\(PrivacySettings.hideIPInformation ? "[IP]" : server.host):\(server.port)`",
            "- System: \(snapshot.distribution) · \(snapshot.kernel)",
            "- Uptime: \(snapshot.uptime)",
            "- CPU: \(DisplayFormat.percent(snapshot.cpuUsage)) · \(snapshot.coreCount) cores",
            "- Load: \(format(snapshot.load1)) / \(format(snapshot.load5)) / \(format(snapshot.load15))",
            "- Memory: \(DisplayFormat.bytes(snapshot.memoryUsedBytes)) / \(DisplayFormat.bytes(snapshot.memoryTotalBytes))",
            "- Network: ↓ \(DisplayFormat.speed(snapshot.downloadBytesPerSecond)) · ↑ \(DisplayFormat.speed(snapshot.uploadBytesPerSecond))"
        ]
        if let root = snapshot.filesystems.first(where: { $0.mountPoint == "/" }) {
            lines.append(
                "- Storage `/`: \(DisplayFormat.bytes(root.usedBytes)) / \(DisplayFormat.bytes(root.totalBytes))"
            )
        }
        if !snapshot.gpus.isEmpty {
            lines.append("- GPU: \(snapshot.gpus.map(\.name).joined(separator: ", "))")
        }
        if snapshot.dockerAvailable {
            lines.append("- Docker: \(snapshot.dockerContainers.count) containers")
        }
        if let location = snapshot.geoLocation,
           !PrivacySettings.hideIPInformation,
           !PrivacySettings.disableLocationLookup {
            lines.append("- Location: \(location.city), \(location.country)")
        }
        return lines.joined(separator: "\n")
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }
}
