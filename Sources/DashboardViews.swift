import Charts
import SwiftUI

struct DashboardOverviewView: View {
    @EnvironmentObject private var appState: AppState

    let servers: [ServerRecord]
    let onSelect: (ServerRecord) -> Void
    let onAdd: () -> Void

    private var onlineCount: Int {
        servers.filter { appState.status(for: $0) == .online }.count
    }

    private var offlineCount: Int {
        servers.filter {
            let status = appState.status(for: $0)
            return status == .failed || status == .offline
        }.count
    }

    private var refreshingCount: Int {
        servers.filter { appState.isRefreshing($0) }.count
    }

    private var averageCPU: Double {
        let online = servers.filter { appState.status(for: $0) == .online }
        guard !online.isEmpty else { return 0 }
        return online.reduce(0) { $0 + appState.snapshot(for: $1).cpuUsage } / Double(online.count)
    }

    private var refreshTaskID: String {
        servers.map(\.id.uuidString).joined(separator: ",") + ":\(appState.refreshInterval)"
    }

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
                    AppleUnifiedPanel {
                        HStack(spacing: 0) {
                        DashboardSummaryCard(
                            title: "服务器总数",
                            value: "\(servers.count)",
                            subtitle: "平均 CPU \(DisplayFormat.percent(averageCPU))",
                            icon: "server.rack",
                            tint: .appAccent
                        )
                        Divider().frame(height: 64)
                        DashboardSummaryCard(
                            title: "在线",
                            value: "\(onlineCount)",
                            subtitle: refreshingCount > 0 ? "\(refreshingCount) 台后台刷新" : "资源采集正常",
                            icon: "checkmark.circle.fill",
                            tint: .appLive
                        )
                        Divider().frame(height: 64)
                        DashboardSummaryCard(
                            title: "离线 / 异常",
                            value: "\(offlineCount)",
                            subtitle: offlineCount == 0 ? "所有服务器状态正常" : "请检查连接或认证",
                            icon: "exclamationmark.triangle.fill",
                            tint: offlineCount == 0 ? .secondary : .appError
                        )
                        }
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 310), spacing: 14)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(servers) { server in
                            VPSSummaryCard(
                                server: server,
                                onSelect: { onSelect(server) }
                            )
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1100, alignment: .leading)
        }
        .task(id: refreshTaskID) {
            await monitorAllServers()
        }
    }

    private func monitorAllServers() async {
        guard !servers.isEmpty else { return }
        await appState.refreshAll(servers)

        while !Task.isCancelled, appState.refreshInterval > 0 {
            do {
                try await Task.sleep(for: .seconds(appState.refreshInterval))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await appState.refreshAll(servers)
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
    @EnvironmentObject private var appState: AppState

    let server: ServerRecord
    let onSelect: () -> Void

    private var snapshot: ServerSnapshot { appState.snapshot(for: server) }
    private var status: ServerConnectionStatus { appState.status(for: server) }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                StatusDot(status: status)
                Text(server.name)
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Text(status.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor)
                Button {
                    appState.openTerminal(for: server)
                } label: {
                    Image(systemName: "terminal")
                }
                .buttonStyle(CompactActionButtonStyle())
                .help("打开 SSH 终端")
                .accessibilityLabel("打开 \(server.name) SSH 终端")
            }

            HStack(spacing: 12) {
                DashboardMetadata(icon: "cpu", value: "\(snapshot.coreCount) 核")
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
                        leading: snapshot.load1.formatted(.number.precision(.fractionLength(2))),
                        trailing: "\(snapshot.processCount) 进程"
                    )
                }
                .frame(maxWidth: .infinity)
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
        if let error = appState.errors[server.id] {
            return error
        }
        if status == .unknown {
            return "等待首次资源采集"
        }
        return "\(snapshot.distribution) · \(server.host)"
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
    @EnvironmentObject private var appState: AppState

    let server: ServerRecord
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var snapshot: ServerSnapshot { appState.snapshot(for: server) }
    private var status: ServerConnectionStatus { appState.status(for: server) }

    var body: some View {
        VStack(spacing: 0) {
            ServerDetailHeader(
                server: server,
                status: status,
                mode: $appState.detailMode,
                onEdit: onEdit,
                onDelete: onDelete
            )
            Divider().opacity(0.55)

            switch appState.detailMode {
            case .monitor:
                monitoringContent
            case .terminal:
                TerminalWorkspaceView(server: server)
            case .sftp:
                SFTPBrowserView(server: server)
            }
        }
        .background(Color.appGround)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var monitoringContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = appState.errors[server.id], status == .failed {
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
                        subtitle: "负载 \(snapshot.load1.formatted(.number.precision(.fractionLength(1)))) / \(snapshot.load5.formatted(.number.precision(.fractionLength(1)))) / \(snapshot.load15.formatted(.number.precision(.fractionLength(1))))",
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

                ResourceTrendCard(points: appState.history(for: server))
                SystemAndProcessesCard(snapshot: snapshot)
            }
            .padding(18)
            .frame(maxWidth: 1200, alignment: .leading)
        }
    }
}

private struct ServerDetailHeader: View {
    @EnvironmentObject private var appState: AppState

    let server: ServerRecord
    let status: ServerConnectionStatus
    @Binding var mode: DetailMode
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: status, size: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 20, weight: .bold))
                Text("\(server.username)@\(server.host):\(server.port)")
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
                Text("\(snapshot.processCount) 个进程 · \(snapshot.loggedInUsers) 位登录用户")
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
                    Text(process.cpu.formatted(.number.precision(.fractionLength(1))) + "%")
                        .monospacedDigit()
                }
                .width(70)
                TableColumn("内存") { process in
                    Text(process.memory.formatted(.number.precision(.fractionLength(1))) + "%")
                        .monospacedDigit()
                }
                .width(70)
            }
            .frame(height: 170)
        }
        .applePanel()
    }
}
