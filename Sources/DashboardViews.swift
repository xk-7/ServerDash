import AppKit
import SwiftUI

struct DashboardOverviewView: View {
    @EnvironmentObject private var appState: AppState
    @SceneStorage("dashboard.filter.search") private var searchText = ""
    @SceneStorage("dashboard.filter.group") private var selectedGroup = ""
    @SceneStorage("dashboard.filter.tag") private var selectedTag = ""
    @SceneStorage("dashboard.sort") private var sortRawValue = ServerBrowserSort.name.rawValue

    let servers: [ServerRecord]
    @Binding var scrollAnchor: UUID?
    let onSelect: (ServerRecord) -> Void
    let onOpenTerminal: (ServerRecord) -> Void
    let onAdd: () -> Void

    private var query: ServerBrowserQuery {
        ServerBrowserQuery(search: searchText, group: selectedGroup, tag: selectedTag,
                           sort: ServerBrowserSort(rawValue: sortRawValue) ?? .name)
    }

    private var visibleServers: [ServerRecord] { query.apply(to: servers) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                AppleWorkspaceHeader(
                    title: "仪表盘",
                    subtitle: "服务器运行状况，一目了然。",
                    symbol: "gauge.with.dots.needle.50percent"
                ) {
                    Button("添加服务器", systemImage: "plus", action: onAdd)
                        .buttonStyle(.borderedProminent)
                }

                if servers.isEmpty {
                    ContentUnavailableView {
                        Label("连接你的第一台服务器", systemImage: "server.rack")
                    } description: {
                        Text("集中查看资源状态，打开 SSH 终端，或管理远程文件。")
                    } actions: {
                        Button("添加服务器", systemImage: "plus", action: onAdd)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .applePanel()
                } else {
                    DashboardFleetSummary(serverCount: servers.count, state: appState.fleetSummaryState)

                    ServerBrowserControls(
                        servers: servers, search: $searchText, group: $selectedGroup,
                        tag: $selectedTag, sortRawValue: $sortRawValue
                    )

                    HStack {
                        Text("服务器概览")
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        if query.hasFilters {
                            Text("\(DisplayFormat.integer(visibleServers.count)) / \(DisplayFormat.integer(servers.count)) 台")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Label(
                            appState.refreshInterval > 0
                                ? "每 \(DisplayFormat.integer(Int(appState.refreshInterval))) 秒刷新"
                                : "手动刷新",
                            systemImage: appState.refreshInterval > 0 ? "arrow.clockwise" : "pause.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280), spacing: AppleDesign.Spacing.md, alignment: .top)],
                        alignment: .leading,
                        spacing: AppleDesign.Spacing.md
                    ) {
                        ForEach(visibleServers) { server in
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
                    if visibleServers.isEmpty {
                        ContentUnavailableView {
                            Label("没有匹配的服务器", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("筛选只影响显示，后台监控仍按原设置运行。")
                        } actions: {
                            Button("清除筛选") {
                                searchText = ""
                                selectedGroup = ""
                                selectedTag = ""
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .applePanel()
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: AppleDesign.Layout.contentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition(id: $scrollAnchor, anchor: .center)
        .onChange(of: visibleServers.map(\.id)) { _, ids in
            if let scrollAnchor, !ids.contains(scrollAnchor) { self.scrollAnchor = ids.first }
        }
    }
}

private struct DashboardFleetSummary: View {
    let serverCount: Int
    @ObservedObject var state: FleetMonitoringSummaryState

    private var summary: FleetMonitoringSummary { state.value }
    private var pendingCount: Int { max(0, serverCount - summary.onlineCount - summary.issueCount) }

    var body: some View {
        AppleUnifiedPanel {
            HStack(alignment: .top, spacing: 0) {
                DashboardSummaryCard(
                    title: "全部服务器",
                    value: DisplayFormat.integer(serverCount),
                    subtitle: summary.onlineCount > 0
                        ? "在线平均 CPU \(DisplayFormat.percent(summary.averageCPU))"
                        : "等待资源采集",
                    icon: "server.rack", tint: .primary
                )
                Divider().padding(.vertical, AppleDesign.Spacing.lg)
                DashboardSummaryCard(
                    title: "在线",
                    value: DisplayFormat.integer(summary.onlineCount),
                    subtitle: summary.refreshingCount > 0
                        ? "\(DisplayFormat.integer(summary.refreshingCount)) 台正在刷新"
                        : (pendingCount > 0 ? "\(DisplayFormat.integer(pendingCount)) 台等待检测" : "已完成状态检测"),
                    icon: "checkmark.circle", tint: .appLive
                )
                Divider().padding(.vertical, AppleDesign.Spacing.lg)
                DashboardSummaryCard(
                    title: "需要关注",
                    value: DisplayFormat.integer(summary.issueCount),
                    subtitle: summary.issueCount > 0 ? "连接中断或认证异常" : "暂无已知连接异常",
                    icon: "exclamationmark.circle",
                    tint: summary.issueCount > 0 ? .appError : .secondary
                )
            }
            .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
            Label(title, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppleDesign.Spacing.lg)
        .accessibilityElement(children: .combine)
    }
}

private struct VPSSummaryCard: View {
    let server: ServerRecord
    @ObservedObject var runtime: ServerRuntimeState
    let refreshInterval: TimeInterval
    let onVisibilityChange: (Bool) -> Void
    let onSelect: () -> Void
    let onOpenTerminal: () -> Void
    @AppStorage("hideIPInformation") private var hideIPInformation = false

    private var snapshot: ServerSnapshot { runtime.renderState.snapshot }
    private var status: ServerConnectionStatus { runtime.renderState.status }

    var body: some View {
        let _ = PerformanceTrace.event(.dashboardCardBodyUpdate)
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                    HStack {
                        Label(server.groupName, systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: AppleDesign.Spacing.xs)
                        ServerStatusBadge(status: status)
                    }
                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                        Text(server.displayName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .help(server.displayName)
                        Text(hideIPInformation ? "[IP]" : server.host)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !server.tags.isEmpty {
                            Label(server.tags.joined(separator: " · "), systemImage: "tag")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .help(server.tags.joined(separator: " · "))
                        }
                    }

                    if runtime.renderState.hasSnapshot {
                        HStack(spacing: AppleDesign.Spacing.md) {
                            DashboardResourceMetric(title: "CPU", value: snapshot.cpuUsage)
                            DashboardResourceMetric(title: "内存", value: snapshot.memoryUsage)
                            DashboardResourceMetric(title: "磁盘", value: snapshot.diskUsage)
                        }
                        HStack(spacing: AppleDesign.Spacing.md) {
                            Label(DisplayFormat.speed(snapshot.downloadBytesPerSecond), systemImage: "arrow.down")
                            Label(DisplayFormat.speed(snapshot.uploadBytesPerSecond), systemImage: "arrow.up")
                        }
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else {
                        HStack(spacing: AppleDesign.Spacing.sm) {
                            if runtime.renderState.isRefreshing || status == .connecting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: status == .failed ? "exclamationmark.circle" : "clock")
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                                Text(status == .failed ? "暂时无法采集" : "等待首次资源采集")
                                    .font(.callout.weight(.medium))
                                Text("采集完成后显示资源使用情况")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: 88)
                    }
                }
                .padding(AppleDesign.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("打开服务器监控详情")

            Divider().padding(.horizontal, AppleDesign.Spacing.md)

            HStack(spacing: AppleDesign.Spacing.xs) {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(status == .failed || status == .offline ? Color.appError : .secondary)
                    .lineLimit(1)
                    .help(footerText)
                Spacer(minLength: AppleDesign.Spacing.xxs)
                Button(action: onOpenTerminal) {
                    Label("终端", systemImage: "terminal")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help("打开 \(server.displayName) 的 SSH 终端")
                .accessibilityLabel("打开 \(server.displayName) 的 SSH 终端")
            }
            .padding(AppleDesign.Spacing.md)
        }
        .applePanel(padding: 0, radius: AppleDesign.Radius.card)
        .appleInteractiveSurface()
        .onAppear { onVisibilityChange(true) }
        .onDisappear { onVisibilityChange(false) }
    }

    private var footerText: String {
        if let error = runtime.renderState.error { return error }
        if runtime.renderState.isStale(refreshInterval: refreshInterval) { return "数据已过期 · 保留上次结果" }
        guard runtime.renderState.hasSnapshot else { return server.verificationStatus.title }
        return "\(snapshot.distribution) · \(DisplayFormat.integer(snapshot.coreCount)) 核"
    }
}

private struct DashboardResourceMetric: View {
    let title: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(DisplayFormat.percent(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            MonitorLinearGauge(value: value)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
            HStack(spacing: AppleDesign.Spacing.sm) {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                }
                .help("返回\(backTitle)")
                .accessibilityLabel("返回\(backTitle)")
                .keyboardShortcut("[", modifiers: .command)

                VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                    Text(server.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                        .help(server.displayName)
                    Text(headerSubtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(headerSubtitle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ServerStatusBadge(status: status)
            }
            HStack(spacing: AppleDesign.Spacing.sm) {
                Picker("视图", selection: $mode) {
                    ForEach(DetailMode.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                Spacer(minLength: AppleDesign.Spacing.xs)
                if mode == .monitor {
                    Button {
                        Task { await appState.refresh(server) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(runtime.renderState.isRefreshing)
                    .help("刷新此服务器的监控数据")
                }
                Menu {
                    Button("事件日志", systemImage: "list.bullet.rectangle", action: onEventLog)
                    if runtime.renderState.diagnostics != nil {
                        Button("诊断", systemImage: "stethoscope", action: onDiagnostics)
                    }
                    Divider()
                    Button("编辑服务器", systemImage: "pencil", action: onEdit)
                    Button("删除服务器", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .help("服务器操作")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .padding(AppleDesign.Spacing.lg)
        .background(Color.appGround)
    }
}
