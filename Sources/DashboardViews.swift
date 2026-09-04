import AppKit
import Charts
import SwiftUI

struct DashboardOverviewView: View {
    @EnvironmentObject private var appState: AppState

    let servers: [ServerRecord]
    @Binding var scrollAnchor: UUID?
    let onSelect: (ServerRecord) -> Void
    let onOpenTerminal: (ServerRecord) -> Void
    let onAdd: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("仪表盘")
                            .font(.system(size: 22, weight: .bold))
                        Text("集中查看全部 VPS 的实时资源状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if servers.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("还没有服务器")
                            .font(.title3.bold())
                        Text("添加第一台 VPS 后，即可查看资源监控并建立 SSH 连接。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("添加服务器", systemImage: "plus", action: onAdd)
                            .buttonStyle(.borderedProminent)
                            .tint(.appAccent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 340)
                    .applePanel()
                } else {
                    DashboardFleetSummary(
                        serverCount: servers.count,
                        state: appState.fleetSummaryState
                    )

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 310), spacing: 14)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(servers) { server in
                            VPSSummaryCard(
                                server: server,
                                runtime: appState.runtime(for: server),
                                refreshInterval: appState.refreshInterval,
                                onVisibilityChange: { visible in
                                    appState.setMonitorVisible(visible, serverID: server.id)
                                },
                                onSelect: { onSelect(server) },
                                onOpenTerminal: { onOpenTerminal(server) }
                            )
                            .id(server.id)
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .scrollPosition(id: $scrollAnchor, anchor: .center)
    }
}

private struct DashboardFleetSummary: View {
    let serverCount: Int
    @ObservedObject var state: FleetMonitoringSummaryState

    private var summary: FleetMonitoringSummary { state.value }

    var body: some View {
        AppleUnifiedPanel {
            HStack(spacing: 0) {
                DashboardSummaryCard(
                    title: "服务器总数",
                    value: DisplayFormat.integer(serverCount),
                    subtitle: "平均 CPU \(DisplayFormat.percent(summary.averageCPU))",
                    icon: "server.rack",
                    tint: .appAccent
                )
                Divider().frame(height: 64)
                DashboardSummaryCard(
                    title: "在线",
                    value: DisplayFormat.integer(summary.onlineCount),
                    subtitle: summary.refreshingCount > 0
                        ? "\(DisplayFormat.integer(summary.refreshingCount)) 台后台刷新"
                        : "资源采集正常",
                    icon: "checkmark.circle.fill",
                    tint: .appLive
                )
                Divider().frame(height: 64)
                DashboardSummaryCard(
                    title: "离线 / 异常",
                    value: DisplayFormat.integer(summary.issueCount),
                    subtitle: summary.issueCount == 0
                        ? "所有服务器状态正常"
                        : "请检查连接或认证",
                    icon: "exclamationmark.triangle.fill",
                    tint: summary.issueCount == 0 ? .secondary : .appError
                )
            }
        }
    }
}

private struct DashboardSummaryCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AppleDesign.Radius.thumbnail, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(AppleDesign.Spacing.md)
        .frame(maxWidth: .infinity)
    }
}

private struct VPSSummaryCard: View {
    let server: ServerRecord
    @ObservedObject var runtime: ServerRuntimeState
    let refreshInterval: TimeInterval
    let onVisibilityChange: (Bool) -> Void
    let onSelect: () -> Void
    let onOpenTerminal: () -> Void

    private var snapshot: ServerSnapshot { runtime.renderState.snapshot }
    private var status: ServerConnectionStatus { runtime.renderState.status }

    var body: some View {
        let _ = PerformanceTrace.event(.dashboardCardBodyUpdate)
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                StatusDot(status: status)
                Text(server.name)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(status.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                Button(action: onOpenTerminal) {
                    Image(systemName: "terminal")
                }
                .buttonStyle(CompactActionButtonStyle())
                .help("打开 SSH 终端")
                .accessibilityLabel("打开 \(server.name) SSH 终端")
            }

            if runtime.renderState.hasSnapshot {
                HStack(spacing: 12) {
                    DashboardMetadata(
                        icon: "cpu",
                        value: "\(DisplayFormat.integer(snapshot.coreCount)) 核"
                    )
                    DashboardMetadata(icon: "memorychip", value: DisplayFormat.bytes(snapshot.memoryTotalBytes))
                    DashboardMetadata(icon: "internaldrive", value: DisplayFormat.bytes(snapshot.diskTotalBytes))
                    Spacer(minLength: 0)
                    DashboardMetadata(icon: "clock", value: snapshot.uptime)
                }

                HStack(spacing: 18) {
                    CircularResourceGauge(title: "CPU", value: snapshot.cpuUsage, tint: .appAccent)
                    CircularResourceGauge(title: "内存", value: snapshot.memoryUsage, tint: .appLive)
                    VStack(spacing: 8) {
                        DashboardResourceRow(
                            title: "磁盘",
                            leading: DisplayFormat.percent(snapshot.diskUsage),
                            trailing: DisplayFormat.bytes(snapshot.diskUsedBytes)
                        )
                        DashboardResourceRow(
                            title: "网络",
                            leading: "↓ \(DisplayFormat.speed(snapshot.downloadBytesPerSecond))",
                            trailing: "↑ \(DisplayFormat.speed(snapshot.uploadBytesPerSecond))"
                        )
                        DashboardResourceRow(
                            title: "负载",
                            leading: DisplayFormat.decimal(snapshot.load1, fractionLength: 2),
                            trailing: "\(DisplayFormat.integer(snapshot.processCount)) 进程"
                        )
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: AppleDesign.Spacing.sm) {
                    if runtime.renderState.isRefreshing || status == .connecting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                        Text("等待首次资源采集")
                            .font(.callout.weight(.semibold))
                        Text("采集完成前不会把空快照显示为真实的 0%。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 105)
            }

            HStack {
                Text(footerText)
                    .font(.caption2)
                    .foregroundStyle(status == .failed ? Color.appError : Color.secondary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.bold())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 190, alignment: .top)
        .applePanel(padding: AppleDesign.Spacing.md, radius: AppleDesign.Radius.card)
        .contentShape(RoundedRectangle(cornerRadius: AppleDesign.Radius.card, style: .continuous))
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            onSelect()
        }
        .onAppear {
            onVisibilityChange(true)
        }
        .onDisappear {
            onVisibilityChange(false)
        }
    }

    private var statusColor: Color {
        switch status {
        case .online: .appLive
        case .connecting: .appWarning
        case .failed, .offline: .appError
        case .unknown: .secondary
        }
    }

    private var footerText: String {
        if let error = runtime.renderState.error {
            return error
        }
        if runtime.renderState.isStale(refreshInterval: refreshInterval) {
            return "监控数据已过期"
        }
        if status == .unknown {
            return server.verificationStatus == .unverified ? "未验证 · 可先离线保存" : "等待首次资源采集"
        }
        let host = PrivacySettings.hideIPInformation ? "[IP]" : server.host
        let latency = server.lastLatencyMS > 0
            ? " · \(DisplayFormat.integer(Int(server.lastLatencyMS))) ms"
            : ""
        return "\(snapshot.distribution) · \(host)\(latency) · \(server.verificationStatus.title)"
    }
}

private struct DashboardMetadata: View {
    let icon: String
    let value: String

    var body: some View {
        Label(value, systemImage: icon)
            .font(.caption2.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct CircularResourceGauge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.15), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(max(value / 100, 0), 1))
                    .stroke(
                        value >= 90 ? Color.appError : tint,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : AppleDesign.quick, value: value)
                Text(DisplayFormat.percent(value))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 54, height: 54)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(DisplayFormat.percent(value))
    }
}

private struct DashboardResourceRow: View {
    let title: String
    let leading: String
    let trailing: String

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(leading)
                Text(trailing)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospaced().weight(.medium))
            Divider().opacity(0.45)
        }
    }
}

struct ServerDetailView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var appState: AppState

    let server: ServerRecord
    @ObservedObject var runtime: ServerRuntimeState
    @Binding var mode: DetailMode
    let backTitle: String
    let onBack: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var presentedOverlay: ServerDetailOverlay?

    private var snapshot: ServerSnapshot { runtime.renderState.snapshot }
    private var status: ServerConnectionStatus { runtime.renderState.status }

    var body: some View {
        VStack(spacing: 0) {
            ServerDetailHeader(
                server: server,
                runtime: runtime,
                status: status,
                mode: $mode,
                backTitle: backTitle,
                onBack: onBack,
                onEdit: onEdit,
                onDelete: onDelete,
                onEventLog: { presentedOverlay = .eventLog },
                onDiagnostics: { presentedOverlay = .diagnostics }
            )
            Divider().opacity(0.55)

            switch mode {
            case .monitor:
                ServerMonitorLayoutView(server: server, runtime: runtime)
            case .terminal:
                TerminalWorkspaceView(server: server)
            case .sftp:
                SFTPBrowserView(server: server)
            }
        }
        .background(Color.appGround)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if let presentedOverlay {
                AppleDismissibleOverlay(
                    maxWidth: presentedOverlay == .eventLog ? 760 : 560,
                    maxHeight: presentedOverlay == .eventLog ? 500 : 420,
                    onDismiss: { self.presentedOverlay = nil }
                ) {
                    switch presentedOverlay {
                    case .eventLog:
                        EventLogView(
                            store: EventLogStore.shared,
                            serverID: server.id,
                            onDismiss: { self.presentedOverlay = nil }
                        )
                    case .diagnostics:
                        DiagnosticsPreviewView(
                            text: runtime.renderState.diagnostics ?? "暂无诊断信息。",
                            onDismiss: { self.presentedOverlay = nil }
                        ) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                runtime.renderState.diagnostics ?? "",
                                forType: .string
                            )
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : AppleDesign.quick, value: presentedOverlay)
    }

    private var monitoringContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = runtime.renderState.error, status == .failed {
                    HStack(spacing: 9) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.appError)
                        Text(error)
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        Button("重试") {
                            Task { await appState.refresh(server) }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(11)
                    .background(Color.appError.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: AppleDesign.Radius.thumbnail, style: .continuous))
                }

                AppleUnifiedPanel {
                    HStack(alignment: .top, spacing: 0) {
                    MetricCard(
                        title: "CPU",
                        value: DisplayFormat.percent(snapshot.cpuUsage),
                        subtitle: "负载 \(DisplayFormat.decimal(snapshot.load1, fractionLength: 1)) / \(DisplayFormat.decimal(snapshot.load5, fractionLength: 1)) / \(DisplayFormat.decimal(snapshot.load15, fractionLength: 1))",
                        progress: snapshot.cpuUsage / 100,
                        tint: .appAccent
                    )
                    Divider().frame(height: 112)
                    MetricCard(
                        title: "内存",
                        value: DisplayFormat.percent(snapshot.memoryUsage),
                        subtitle: "\(DisplayFormat.bytes(snapshot.memoryUsedBytes)) / \(DisplayFormat.bytes(snapshot.memoryTotalBytes))",
                        progress: snapshot.memoryUsage / 100,
                        tint: .appLive
                    )
                    Divider().frame(height: 112)
                    MetricCard(
                        title: "磁盘",
                        value: DisplayFormat.percent(snapshot.diskUsage),
                        subtitle: "\(DisplayFormat.bytes(snapshot.diskUsedBytes)) / \(DisplayFormat.bytes(snapshot.diskTotalBytes))",
                        progress: snapshot.diskUsage / 100,
                        tint: .secondary
                    )
                    Divider().frame(height: 112)
                    MetricCard(
                        title: "网络",
                        value: "↓ \(DisplayFormat.speed(snapshot.downloadBytesPerSecond))",
                        subtitle: "↑ \(DisplayFormat.speed(snapshot.uploadBytesPerSecond))",
                        progress: min(1, snapshot.downloadBytesPerSecond / 10_000_000),
                        tint: .appLive
                    )
                    }
                }

                ResourceTrendCard(points: runtime.renderState.history)
                SystemAndProcessesCard(snapshot: snapshot)
            }
            .padding(18)
            .frame(maxWidth: 1200, alignment: .leading)
        }
    }
}

private enum ServerDetailOverlay: Equatable {
    case eventLog
    case diagnostics
}

private struct ServerDetailHeader: View {
    @EnvironmentObject private var appState: AppState

    let server: ServerRecord
    @ObservedObject var runtime: ServerRuntimeState
    let status: ServerConnectionStatus
    @Binding var mode: DetailMode
    let backTitle: String
    let onBack: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onEventLog: () -> Void
    let onDiagnostics: () -> Void

    private var headerSubtitle: String {
        let host = PrivacySettings.hideIPInformation ? "[IP]" : server.host
        var parts = ["\(server.username)@\(host):\(server.port)", server.verificationStatus.title]
        if server.lastLatencyMS > 0 {
            parts.append("\(DisplayFormat.integer(Int(server.lastLatencyMS))) ms")
        }
        if runtime.renderState.isStale(refreshInterval: appState.refreshInterval) {
            parts.append("数据已过期")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    var body: some View {
        if mode == .terminal {
            terminalHeader
        } else {
            standardHeader
        }
    }

    private var terminalHeader: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
            }
            .help("返回\(backTitle)")
            .accessibilityLabel("返回\(backTitle)")
            .keyboardShortcut("[", modifiers: .command)

            Text(server.displayName)
                .font(.headline)
                .lineLimit(1)
                .help(server.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            Picker("视图", selection: $mode) {
                ForEach(DetailMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            Menu {
                Button("事件日志", systemImage: "list.bullet.rectangle", action: onEventLog)
                if runtime.renderState.diagnostics != nil {
                    Button("诊断", systemImage: "stethoscope", action: onDiagnostics)
                }
                Divider()
                Button("编辑服务器", systemImage: "pencil", action: onEdit)
                Button("删除服务器", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("服务器操作")
            .accessibilityLabel("服务器操作")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(.horizontal, AppleDesign.Spacing.md)
        .padding(.vertical, AppleDesign.Spacing.xs)
        .background(Color.appGround)
    }

    private var standardHeader: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("返回\(backTitle)", systemImage: "chevron.backward")
            }
            .help("返回\(backTitle)")
            .keyboardShortcut("[", modifiers: .command)
            StatusDot(status: status, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .font(.system(size: 20, weight: .bold))
                Text(headerSubtitle)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Picker("视图", selection: $mode) {
                ForEach(DetailMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            Spacer()
            Button {
                Task { await appState.refresh(server) }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Button("事件", systemImage: "list.bullet.rectangle", action: onEventLog)
            if runtime.renderState.diagnostics != nil {
                Button("诊断", systemImage: "stethoscope", action: onDiagnostics)
            }
            Button {
                appState.openTerminal(for: server)
            } label: {
                Label("SSH 连接", systemImage: "terminal")
            }
            .buttonStyle(.borderedProminent)
            .tint(.appAccent)
            Button {
                appState.detailMode = .sftp
            } label: {
                Label("SFTP", systemImage: "folder")
            }
            Menu {
                Button("编辑服务器", systemImage: "pencil", action: onEdit)
                Divider()
                Button("删除服务器", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Color.appGround)
    }
}

private struct ResourceTrendCard: View {
    let points: [MetricPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("近期趋势")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                HStack(spacing: 12) {
                    LegendDot(color: .appAccent, text: "CPU")
                    LegendDot(color: .appLive, text: "内存")
                }
            }
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("CPU", point.cpu)
                    )
                    .foregroundStyle(Color.appAccent)
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("内存", point.memory)
                    )
                    .foregroundStyle(Color.appLive)
                    .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
        }
        .applePanel()
    }
}

private struct LegendDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct SystemAndProcessesCard: View {
    let snapshot: ServerSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("系统与进程")
                        .font(.system(size: 14, weight: .bold))
                    Text("\(snapshot.distribution) · \(snapshot.kernel) · 已运行 \(snapshot.uptime)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(
                    "\(DisplayFormat.integer(snapshot.processCount)) 个进程 · " +
                    "\(DisplayFormat.integer(snapshot.loggedInUsers)) 位登录用户"
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Table(snapshot.topProcesses) {
                TableColumn("进程") { process in
                    Text(process.name)
                        .fontWeight(.semibold)
                }
                TableColumn("PID") { process in
                    Text("\(process.pid)").monospacedDigit()
                }
                .width(70)
                TableColumn("CPU") { process in
                    Text(DisplayFormat.decimal(process.cpu, fractionLength: 1) + "%")
                        .monospacedDigit()
                }
                .width(70)
                TableColumn("内存") { process in
                    Text(DisplayFormat.decimal(process.memory, fractionLength: 1) + "%")
                        .monospacedDigit()
                }
                .width(70)
            }
            .frame(height: 170)
        }
        .applePanel()
    }
}
