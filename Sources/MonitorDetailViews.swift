import Charts
import Foundation
import SwiftUI

struct MemoryBreakdown: Equatable {
    let used: Double
    let cached: Double
    let buffers: Double
    let free: Double
}

struct DockerStatusSummary: Equatable {
    let running: Int
    let stopped: Int
    let other: Int

    var total: Int { running + stopped + other }
}

struct GPUStatusSummary: Equatable {
    let deviceCount: Int
    let processCount: Int
    let peakUtilization: Double?
    let peakTemperature: Double?
}

enum MonitorProcessSortField: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case pid
    case name
    case user
    case threads
    case arguments

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

enum DockerStateFilter: String, CaseIterable, Identifiable {
    case all
    case running
    case stopped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "全部"
        case .running: "运行中"
        case .stopped: "已停止"
        }
    }
}

enum MonitorPresentation {
    static func memoryBreakdown(_ snapshot: ServerSnapshot) -> MemoryBreakdown {
        MemoryBreakdown(
            used: max(0, snapshot.memoryUsedBytes),
            cached: max(0, snapshot.memoryCachedBytes - snapshot.memoryBuffersBytes),
            buffers: max(0, snapshot.memoryBuffersBytes),
            free: max(0, snapshot.memoryFreeBytes)
        )
    }

    static func orderedFilesystems(
        _ filesystems: [FilesystemMetric],
        pinnedMountPoint: String?
    ) -> [FilesystemMetric] {
        filesystems.sorted { lhs, rhs in
            if lhs.mountPoint == pinnedMountPoint { return true }
            if rhs.mountPoint == pinnedMountPoint { return false }
            if lhs.mountPoint == "/" { return true }
            if rhs.mountPoint == "/" { return false }
            return lhs.mountPoint.localizedStandardCompare(rhs.mountPoint) == .orderedAscending
        }
    }

    static func processes(
        _ processes: [ProcessMetric],
        searchText: String,
        sortField: MonitorProcessSortField,
        descending: Bool
    ) -> [ProcessMetric] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = processes.filter {
            query.isEmpty ||
            String($0.pid).localizedCaseInsensitiveContains(query) ||
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.user.localizedCaseInsensitiveContains(query) ||
            $0.arguments.localizedCaseInsensitiveContains(query)
        }
        return filtered.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortField {
            case .cpu:
                comparison = compare(lhs.cpu, rhs.cpu)
            case .memory:
                comparison = compare(lhs.memory, rhs.memory)
            case .pid:
                comparison = compare(lhs.pid, rhs.pid)
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .user:
                comparison = lhs.user.localizedStandardCompare(rhs.user)
            case .threads:
                comparison = compare(lhs.threadCount, rhs.threadCount)
            case .arguments:
                comparison = lhs.arguments.localizedStandardCompare(rhs.arguments)
            }
            return descending
                ? comparison == .orderedDescending
                : comparison == .orderedAscending
        }
    }

    static func dockerSummary(_ containers: [DockerContainerMetric]) -> DockerStatusSummary {
        var running = 0
        var stopped = 0
        var other = 0
        for container in containers {
            switch container.state.lowercased() {
            case "running":
                running += 1
            case "exited", "stopped", "dead", "created":
                stopped += 1
            default:
                other += 1
            }
        }
        return DockerStatusSummary(running: running, stopped: stopped, other: other)
    }

    static func gpuSummary(_ snapshot: ServerSnapshot) -> GPUStatusSummary {
        GPUStatusSummary(
            deviceCount: snapshot.gpus.count,
            processCount: snapshot.gpuProcesses.count,
            peakUtilization: snapshot.gpus.map(\.utilization).max(),
            peakTemperature: snapshot.gpus.compactMap(\.temperatureCelsius).max()
        )
    }

    static func dockerContainers(
        _ containers: [DockerContainerMetric],
        searchText: String,
        filter: DockerStateFilter
    ) -> [DockerContainerMetric] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return containers.filter { container in
            let matchesQuery = query.isEmpty ||
                container.name.localizedCaseInsensitiveContains(query) ||
                container.image.localizedCaseInsensitiveContains(query) ||
                container.status.localizedCaseInsensitiveContains(query)
            guard matchesQuery else { return false }
            switch filter {
            case .all:
                return true
            case .running:
                return container.state.lowercased() == "running"
            case .stopped:
                return container.state.lowercased() != "running"
            }
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}

struct MemoryDashboardDetailView: View {
    let snapshot: ServerSnapshot
    let history: [MetricPoint]

    private var breakdown: MemoryBreakdown {
        MonitorPresentation.memoryBreakdown(snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                HStack(spacing: AppleDesign.Spacing.lg) {
                    ResourceUsageRing(
                        value: snapshot.memoryUsage,
                        title: "内存使用率",
                        symbol: "memorychip"
                    )
                    Divider().frame(height: 120)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150))],
                        spacing: AppleDesign.Spacing.md
                    ) {
                        MonitorStatTile(
                            title: "已用",
                            value: DisplayFormat.bytes(breakdown.used),
                            symbol: "chart.pie.fill"
                        )
                        MonitorStatTile(
                            title: "缓存",
                            value: DisplayFormat.bytes(breakdown.cached),
                            symbol: "shippingbox"
                        )
                        MonitorStatTile(
                            title: "空闲",
                            value: DisplayFormat.bytes(breakdown.free),
                            symbol: "checkmark.circle",
                            tint: .appLive
                        )
                        MonitorStatTile(
                            title: "Swap",
                            value: snapshot.swapTotalBytes > 0
                                ? DisplayFormat.percent(snapshot.swapUsage)
                                : "N/A",
                            symbol: "arrow.left.arrow.right"
                        )
                    }
                }
                .applePanel(padding: AppleDesign.Spacing.lg, radius: AppleDesign.Radius.card)

                MonitorSectionPanel(
                    title: "内存与 Swap 趋势",
                    subtitle: "最近 \(DisplayFormat.integer(min(history.count, 120))) 个采样点"
                ) {
                    if history.isEmpty {
                        MonitorDetailEmptyState(
                            title: "等待历史数据",
                            description: "完成刷新后开始绘制内存趋势。",
                            symbol: "chart.xyaxis.line"
                        )
                    } else {
                        Chart(Array(history.suffix(120))) { point in
                            LineMark(
                                x: .value("时间", point.date),
                                y: .value("内存", point.memory),
                                series: .value("指标", "内存")
                            )
                            .foregroundStyle(Color.appAccent)
                            .interpolationMethod(.catmullRom)
                            LineMark(
                                x: .value("时间", point.date),
                                y: .value("Swap", point.swapUsage),
                                series: .value("指标", "Swap")
                            )
                            .foregroundStyle(Color.appWarning)
                            .interpolationMethod(.catmullRom)
                        }
                        .chartYScale(domain: 0...100)
                        .chartYAxis {
                            AxisMarks(values: [0, 25, 50, 75, 100])
                        }
                        .chartForegroundStyleScale([
                            "内存": Color.appAccent,
                            "Swap": Color.appWarning
                        ])
                        .frame(height: 220)
                    }
                }

                MonitorSectionPanel(
                    title: "容量分解",
                    subtitle: "缓存和缓冲区可由系统按需回收"
                ) {
                    MemoryBreakdownRow(
                        title: "应用与系统",
                        value: breakdown.used,
                        total: snapshot.memoryTotalBytes,
                        color: .appAccent
                    )
                    MemoryBreakdownRow(
                        title: "文件缓存",
                        value: breakdown.cached,
                        total: snapshot.memoryTotalBytes,
                        color: .appWarning
                    )
                    MemoryBreakdownRow(
                        title: "缓冲区",
                        value: breakdown.buffers,
                        total: snapshot.memoryTotalBytes,
                        color: .secondary
                    )
                    MemoryBreakdownRow(
                        title: "空闲",
                        value: breakdown.free,
                        total: snapshot.memoryTotalBytes,
                        color: .appLive
                    )
                    Divider()
                    MemoryBreakdownRow(
                        title: "Swap",
                        value: snapshot.swapUsedBytes,
                        total: snapshot.swapTotalBytes,
                        color: .appWarning
                    )
                }
            }
            .padding(AppleDesign.Spacing.lg)
        }
    }
}

private struct MemoryBreakdownRow: View {
    let title: String
    let value: Double
    let total: Double
    let color: Color

    private var percentage: Double {
        guard total > 0 else { return 0 }
        return min(100, max(0, value / total * 100))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text("\(DisplayFormat.bytes(value)) / \(DisplayFormat.bytes(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            MonitorLinearGauge(value: percentage, tint: color)
        }
    }
}

private enum NetworkDashboardMode: String, CaseIterable, Identifiable {
    case live
    case vnStat

    var id: String { rawValue }
    var title: String { self == .live ? "实时" : "vnStat" }
}

struct NetworkDashboardDetailView: View {
    @AppStorage("networkDisplayInBits") private var displayInBits = false

    let server: ServerRecord
    let snapshot: ServerSnapshot
    let history: [MetricPoint]

    @State private var mode: NetworkDashboardMode = .live
    @State private var period: VnStatPeriod = .daily
    @State private var selectedInterface = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("视图", selection: $mode) {
                    ForEach(NetworkDashboardMode.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                Spacer()
                if !snapshot.networkInterfaces.isEmpty {
                    Picker("默认网络接口", selection: $selectedInterface) {
                        ForEach(snapshot.networkInterfaces) {
                            Text($0.name).tag($0.name)
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
            }
            .padding(AppleDesign.Spacing.md)
            Divider()

            if mode == .live {
                networkLiveContent
            } else {
                networkHistoryContent
            }
        }
        .task {
            selectedInterface = UserDefaults.standard.string(
                forKey: "defaultNetworkInterface.\(server.id.uuidString)"
            ) ?? snapshot.activeNetworkInterface
        }
    }

    private var networkLiveContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 170))],
                    spacing: AppleDesign.Spacing.sm
                ) {
                    MonitorStatTile(
                        title: "实时下载",
                        value: NetworkFormat.speed(
                            snapshot.downloadBytesPerSecond,
                            bits: displayInBits
                        ),
                        symbol: "arrow.down",
                        tint: .appAccent,
                        detail: snapshot.activeNetworkInterface
                    )
                    MonitorStatTile(
                        title: "实时上传",
                        value: NetworkFormat.speed(
                            snapshot.uploadBytesPerSecond,
                            bits: displayInBits
                        ),
                        symbol: "arrow.up",
                        tint: .appLive,
                        detail: snapshot.activeNetworkInterface
                    )
                    MonitorStatTile(
                        title: "累计接收",
                        value: NetworkFormat.bytes(
                            snapshot.networkReceivedBytes,
                            bits: displayInBits
                        ),
                        symbol: "tray.and.arrow.down"
                    )
                    MonitorStatTile(
                        title: "累计发送",
                        value: NetworkFormat.bytes(
                            snapshot.networkSentBytes,
                            bits: displayInBits
                        ),
                        symbol: "tray.and.arrow.up"
                    )
                }
                .applePanel()

                MonitorSectionPanel(
                    title: "实时速率趋势",
                    subtitle: "下载与上传"
                ) {
                    if history.isEmpty {
                        MonitorDetailEmptyState(
                            title: "等待网络趋势",
                            description: "完成刷新后开始绘制网络速率。",
                            symbol: "network"
                        )
                    } else {
                        Chart(Array(history.suffix(120))) { point in
                            AreaMark(
                                x: .value("时间", point.date),
                                y: .value(
                                    "下载",
                                    displayInBits ? point.download * 8 : point.download
                                )
                            )
                            .foregroundStyle(Color.appAccent.opacity(0.1))
                            LineMark(
                                x: .value("时间", point.date),
                                y: .value(
                                    "下载",
                                    displayInBits ? point.download * 8 : point.download
                                ),
                                series: .value("方向", "下载")
                            )
                            .foregroundStyle(Color.appAccent)
                            LineMark(
                                x: .value("时间", point.date),
                                y: .value(
                                    "上传",
                                    displayInBits ? point.upload * 8 : point.upload
                                ),
                                series: .value("方向", "上传")
                            )
                            .foregroundStyle(Color.appLive)
                        }
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: 6)) {
                                AxisValueLabel(format: .dateTime.hour().minute())
                            }
                        }
                        .frame(height: 220)
                    }
                }

                MonitorSectionPanel(
                    title: "网络接口",
                    subtitle: "\(DisplayFormat.integer(snapshot.networkInterfaces.count)) 个接口"
                ) {
                    if snapshot.networkInterfaces.isEmpty {
                        MonitorDetailEmptyState(
                            title: "没有接口数据",
                            description: "当前系统未返回网络接口统计。",
                            symbol: "network.slash"
                        )
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 250))],
                            spacing: AppleDesign.Spacing.sm
                        ) {
                            ForEach(snapshot.networkInterfaces) { interface in
                                NetworkInterfaceTile(
                                    interface: interface,
                                    displayInBits: displayInBits
                                )
                            }
                        }
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
        }
    }

    @ViewBuilder
    private var networkHistoryContent: some View {
        if !snapshot.vnStatAvailable {
            MonitorDetailEmptyState(
                title: "未安装 vnStat",
                description: "安装 vnStat 后可查看小时、日、周、月和年流量。",
                symbol: "chart.bar.xaxis"
            )
            .padding(AppleDesign.Spacing.xl)
        } else if snapshot.vnStatCollecting {
            MonitorDetailEmptyState(
                title: "vnStat 正在收集数据",
                description: "稍后刷新即可看到长期流量历史。",
                symbol: "clock.arrow.circlepath"
            )
            .padding(AppleDesign.Spacing.xl)
        } else {
            ScrollView {
                MonitorSectionPanel(
                    title: "长期流量",
                    subtitle: "来源：\(snapshot.vnStatSource)"
                ) {
                    Picker("周期", selection: $period) {
                        ForEach(VnStatPeriod.allCases) {
                            Text($0.title).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    UnifiedVnStatChart(
                        points: snapshot.vnStatHistory.filter { $0.period == period },
                        displayInBits: displayInBits
                    )
                }
                .padding(AppleDesign.Spacing.lg)
            }
        }
    }
}

private struct NetworkInterfaceTile: View {
    let interface: NetworkInterfaceMetric
    let displayInBits: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
            HStack {
                Label(interface.name, systemImage: "network")
                    .font(.callout.weight(.semibold))
                Spacer()
                if interface.isActive {
                    Text("活动")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.appLive)
                }
            }
            HStack {
                NetworkTileValue(
                    title: "下载",
                    value: NetworkFormat.speed(
                        interface.downloadBytesPerSecond,
                        bits: displayInBits
                    ),
                    color: .appAccent
                )
                Spacer()
                NetworkTileValue(
                    title: "上传",
                    value: NetworkFormat.speed(
                        interface.uploadBytesPerSecond,
                        bits: displayInBits
                    ),
                    color: .appLive
                )
            }
            Text(
                "累计 ↓ \(NetworkFormat.bytes(interface.receivedBytes, bits: displayInBits)) · ↑ \(NetworkFormat.bytes(interface.sentBytes, bits: displayInBits))"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .padding(AppleDesign.Spacing.sm)
        .background(Color.appHover)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.thumbnail,
                style: .continuous
            )
        )
    }
}

private struct NetworkTileValue: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(color)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
    }
}

private struct UnifiedVnStatChart: View {
    let points: [VnStatTrafficPoint]
    let displayInBits: Bool

    var body: some View {
        if points.isEmpty {
            MonitorDetailEmptyState(
                title: "当前周期没有数据",
                description: "选择其他周期或等待 vnStat 继续采集。",
                symbol: "chart.bar.xaxis"
            )
        } else {
            Chart(points) { point in
                BarMark(
                    x: .value("时间", point.date),
                    y: .value(
                        "下载",
                        displayInBits ? point.receivedBytes * 8 : point.receivedBytes
                    )
                )
                .foregroundStyle(Color.appAccent)
                BarMark(
                    x: .value("时间", point.date),
                    y: .value(
                        "上传",
                        displayInBits ? point.sentBytes * 8 : point.sentBytes
                    )
                )
                .foregroundStyle(Color.appLive)
            }
            .frame(minHeight: 300)
        }
    }
}

struct StorageDashboardDetailView: View {
    let server: ServerRecord
    let snapshot: ServerSnapshot

    @State private var selectedVolume = ""

    private var orderedFilesystems: [FilesystemMetric] {
        MonitorPresentation.orderedFilesystems(
            snapshot.filesystems,
            pinnedMountPoint: selectedVolume
        )
    }

    private var primaryVolume: FilesystemMetric? {
        orderedFilesystems.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                if let primaryVolume {
                    HStack(spacing: AppleDesign.Spacing.lg) {
                        ResourceUsageRing(
                            value: primaryVolume.usage,
                            title: primaryVolume.mountPoint,
                            symbol: "internaldrive"
                        )
                        Divider().frame(height: 120)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 160))],
                            spacing: AppleDesign.Spacing.md
                        ) {
                            MonitorStatTile(
                                title: "已用",
                                value: DisplayFormat.bytes(primaryVolume.usedBytes),
                                symbol: "externaldrive.fill"
                            )
                            MonitorStatTile(
                                title: "可用",
                                value: DisplayFormat.bytes(
                                    max(0, primaryVolume.totalBytes - primaryVolume.usedBytes)
                                ),
                                symbol: "checkmark.circle",
                                tint: .appLive
                            )
                            MonitorStatTile(
                                title: "总容量",
                                value: DisplayFormat.bytes(primaryVolume.totalBytes),
                                symbol: "cylinder"
                            )
                            MonitorStatTile(
                                title: "文件系统",
                                value: primaryVolume.filesystemType,
                                symbol: "doc.badge.gearshape"
                            )
                        }
                    }
                    .applePanel(padding: AppleDesign.Spacing.lg, radius: AppleDesign.Radius.card)
                }

                MonitorSectionPanel(
                    title: "文件系统",
                    subtitle: "\(DisplayFormat.integer(snapshot.filesystems.count)) 个挂载点"
                ) {
                    HStack {
                        Spacer()
                        if !snapshot.filesystems.isEmpty {
                            Picker("默认卷", selection: $selectedVolume) {
                                ForEach(snapshot.filesystems) {
                                    Text($0.mountPoint).tag($0.mountPoint)
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
                    }
                    if orderedFilesystems.isEmpty {
                        MonitorDetailEmptyState(
                            title: "没有文件系统数据",
                            description: "当前系统未返回可用挂载点。",
                            symbol: "internaldrive"
                        )
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 260))],
                            spacing: AppleDesign.Spacing.sm
                        ) {
                            ForEach(orderedFilesystems) { filesystem in
                                FilesystemDetailTile(filesystem: filesystem)
                            }
                        }
                    }
                }

                MonitorSectionPanel(
                    title: "设备 I/O",
                    subtitle: "\(DisplayFormat.integer(snapshot.diskIO.count)) 个块设备"
                ) {
                    if snapshot.diskIO.isEmpty {
                        MonitorDetailEmptyState(
                            title: "没有设备 I/O 数据",
                            description: "虚拟磁盘或当前内核可能未暴露磁盘统计。",
                            symbol: "waveform.path"
                        )
                    } else {
                        Table(snapshot.diskIO) {
                            TableColumn("设备") {
                                Text($0.device).font(.body.monospaced())
                            }
                            TableColumn("读取") {
                                Text(DisplayFormat.speed($0.readBytesPerSecond))
                                    .monospacedDigit()
                            }
                            TableColumn("写入") {
                                Text(DisplayFormat.speed($0.writeBytesPerSecond))
                                    .monospacedDigit()
                            }
                            TableColumn("读/写 IOPS") {
                                Text(
                                    "\(DisplayFormat.decimal($0.readIOPS, fractionLength: 1)) / " +
                                    "\(DisplayFormat.decimal($0.writeIOPS, fractionLength: 1))"
                                )
                                .monospacedDigit()
                            }
                            TableColumn("读/写延迟") {
                                Text(
                                    "\(DisplayFormat.decimal($0.readLatencyMilliseconds, fractionLength: 1)) / " +
                                    "\(DisplayFormat.decimal($0.writeLatencyMilliseconds, fractionLength: 1)) ms"
                                )
                                .monospacedDigit()
                            }
                        }
                        .frame(minHeight: 240)
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
        }
        .task {
            selectedVolume = UserDefaults.standard.string(
                forKey: "defaultVolume.\(server.id.uuidString)"
            ) ?? snapshot.filesystems.first(where: { $0.mountPoint == "/" })?.mountPoint
                ?? snapshot.filesystems.first?.mountPoint
                ?? ""
        }
    }
}

private struct FilesystemDetailTile: View {
    let filesystem: FilesystemMetric

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(filesystem.mountPoint)
                        .font(.callout.monospaced().weight(.semibold))
                        .lineLimit(1)
                    Text("\(filesystem.device) · \(filesystem.filesystemType)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(DisplayFormat.percent(filesystem.usage))
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(MonitorSeverity.percentage(filesystem.usage).color)
            }
            MonitorLinearGauge(value: filesystem.usage)
            Text(
                "\(DisplayFormat.bytes(filesystem.usedBytes)) / \(DisplayFormat.bytes(filesystem.totalBytes))"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(AppleDesign.Spacing.sm)
        .background(Color.appHover)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.thumbnail,
                style: .continuous
            )
        )
    }
}

struct ProcessDashboardDetailView: View {
    let snapshot: ServerSnapshot

    @State private var searchText = ""
    @State private var sortField: MonitorProcessSortField = .cpu
    @State private var descending = true

    private var rows: [ProcessMetric] {
        MonitorPresentation.processes(
            snapshot.processes,
            searchText: searchText,
            sortField: sortField,
            descending: descending
        )
    }

    private var topCPU: ProcessMetric? {
        snapshot.processes.max { $0.cpu < $1.cpu }
    }

    private var topMemory: ProcessMetric? {
        snapshot.processes.max { $0.memory < $1.memory }
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170))],
                spacing: AppleDesign.Spacing.sm
            ) {
                MonitorStatTile(
                    title: "进程总数",
                    value: DisplayFormat.integer(snapshot.processCount),
                    symbol: "list.bullet.rectangle"
                )
                MonitorStatTile(
                    title: "登录用户",
                    value: DisplayFormat.integer(snapshot.loggedInUsers),
                    symbol: "person.2",
                    tint: .appLive
                )
                MonitorStatTile(
                    title: "最高 CPU",
                    value: topCPU.map { DisplayFormat.percent($0.cpu) } ?? "—",
                    symbol: "cpu",
                    detail: topCPU?.name
                )
                MonitorStatTile(
                    title: "最高内存",
                    value: topMemory.map { DisplayFormat.percent($0.memory) } ?? "—",
                    symbol: "memorychip",
                    tint: .appWarning,
                    detail: topMemory?.name
                )
            }
            .padding(AppleDesign.Spacing.md)

            Divider()

            HStack {
                TextField("搜索 PID、进程名称、用户或参数", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                Text("\(DisplayFormat.integer(rows.count)) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("排序", selection: $sortField) {
                    ForEach(MonitorProcessSortField.allCases) {
                        Text($0.title).tag($0)
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

            if rows.isEmpty {
                MonitorDetailEmptyState(
                    title: searchText.isEmpty ? "没有进程数据" : "没有匹配的进程",
                    description: searchText.isEmpty
                        ? "当前系统未返回进程列表。"
                        : "尝试其他搜索关键词。",
                    symbol: "list.bullet.rectangle"
                )
            } else {
                Table(rows) {
                    TableColumn("PID") {
                        Text("\($0.pid)").monospacedDigit()
                    }
                    .width(65)
                    TableColumn("名称") {
                        Text($0.name).fontWeight(.medium)
                    }
                    .width(min: 100, ideal: 140)
                    TableColumn("用户") {
                        Text($0.user)
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("CPU%") {
                        Text(DisplayFormat.decimal($0.cpu, fractionLength: 1))
                            .monospacedDigit()
                    }
                    .width(65)
                    TableColumn("内存%") {
                        Text(DisplayFormat.decimal($0.memory, fractionLength: 1))
                            .monospacedDigit()
                    }
                    .width(70)
                    TableColumn("线程") {
                        Text(DisplayFormat.integer($0.threadCount)).monospacedDigit()
                    }
                    .width(55)
                    TableColumn("参数") {
                        Text($0.arguments)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct GPUDashboardDetailView: View {
    let snapshot: ServerSnapshot

    private var summary: GPUStatusSummary {
        MonitorPresentation.gpuSummary(snapshot)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
                GPUDetailStatusHeader(snapshot: snapshot, summary: summary)

                if snapshot.gpus.isEmpty {
                    MonitorDetailEmptyState(
                        title: "没有 GPU 数据",
                        description: "当前主机没有受支持的 NVIDIA GPU。",
                        symbol: "display.slash"
                    )
                } else {
                    ForEach(snapshot.gpus) { gpu in
                        GPUDevicePanel(
                            gpu: gpu,
                            processes: snapshot.gpuProcesses.filter { $0.gpuID == gpu.uuid }
                        )
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
        }
    }
}

private struct GPUDetailStatusHeader: View {
    let snapshot: ServerSnapshot
    let summary: GPUStatusSummary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalLayout
            compactLayout
        }
        .applePanel(padding: AppleDesign.Spacing.lg, radius: AppleDesign.Radius.card)
    }

    private var horizontalLayout: some View {
        HStack(spacing: AppleDesign.Spacing.lg) {
            identityBlock
                .fixedSize(horizontal: true, vertical: false)
            Divider().frame(height: 66)
            metadataBlock
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: AppleDesign.Spacing.md)
            statusMetrics
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.md) {
            identityBlock
            metadataBlock
            Divider()
            statusMetrics
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var identityBlock: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            Image(systemName: "display")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.appAccent)
                .frame(width: 48, height: 48)
                .background(Color.appAccent.opacity(0.11))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AppleDesign.Radius.thumbnail,
                        style: .continuous
                    )
                )
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                Text("GPU 状态")
                    .font(.headline)
                HStack(spacing: AppleDesign.Spacing.xs) {
                    Text(summary.deviceCount == 0 ? "未检测到设备" : "NVIDIA")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if summary.deviceCount > 0 {
                        GPUCountBadge(count: summary.deviceCount)
                    }
                }
            }
        }
    }

    private var metadataBlock: some View {
        HStack(spacing: AppleDesign.Spacing.lg) {
            GPUStatusMetadata(
                title: "驱动版本",
                value: snapshot.gpuDriverVersion.isEmpty
                    ? "—"
                    : snapshot.gpuDriverVersion
            )
            GPUStatusMetadata(
                title: "CUDA",
                value: snapshot.cudaVersion.isEmpty
                    ? "—"
                    : snapshot.cudaVersion
            )
        }
    }

    private var statusMetrics: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            GPUStatusMetric(
                title: "最高利用率",
                value: summary.peakUtilization.map(DisplayFormat.percent) ?? "—",
                symbol: "gauge.medium",
                tint: summary.peakUtilization.map {
                    MonitorSeverity.percentage($0).color
                } ?? .secondary
            )
            GPUStatusMetric(
                title: "最高温度",
                value: summary.peakTemperature.map {
                    DisplayFormat.decimal($0, fractionLength: 0) + "°C"
                } ?? "—",
                symbol: "thermometer.medium",
                tint: temperatureTint
            )
            GPUStatusMetric(
                title: "GPU 进程",
                value: DisplayFormat.integer(summary.processCount),
                symbol: "list.bullet.rectangle",
                tint: .appAccent
            )
        }
    }

    private var temperatureTint: Color {
        guard let temperature = summary.peakTemperature else { return .secondary }
        if temperature >= 85 { return .appError }
        if temperature >= 75 { return .appWarning }
        return .appLive
    }
}

private struct GPUCountBadge: View {
    let count: Int

    var body: some View {
        Text("\(DisplayFormat.integer(count)) 台")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(Color.appAccent)
            .padding(.horizontal, AppleDesign.Spacing.xs)
            .padding(.vertical, AppleDesign.Spacing.xxs)
            .background(Color.appAccent.opacity(0.1))
            .clipShape(Capsule())
    }
}

private struct GPUStatusMetadata: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
    }
}

private struct GPUStatusMetric: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.xs) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.1))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospacedDigit().weight(.bold))
            }
        }
        .padding(.horizontal, AppleDesign.Spacing.xs)
        .padding(.vertical, AppleDesign.Spacing.xs)
        .background(Color.appHover)
        .clipShape(
            RoundedRectangle(
                cornerRadius: AppleDesign.Radius.thumbnail,
                style: .continuous
            )
        )
    }
}

private struct GPUDevicePanel: View {
    let gpu: GPUMetric
    let processes: [GPUProcessMetric]

    private var memoryUsage: Double {
        guard gpu.memoryTotalBytes > 0 else { return 0 }
        return gpu.memoryUsedBytes / gpu.memoryTotalBytes * 100
    }

    var body: some View {
        MonitorSectionPanel(
            title: "GPU \(gpu.index) · \(gpu.name)",
            subtitle: gpu.uuid
        ) {
            HStack(spacing: AppleDesign.Spacing.lg) {
                ResourceUsageRing(
                    value: gpu.utilization,
                    title: "GPU 利用率",
                    symbol: "display"
                )
                Divider().frame(height: 120)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 145))],
                    spacing: AppleDesign.Spacing.md
                ) {
                    MonitorStatTile(
                        title: "显存",
                        value: DisplayFormat.percent(memoryUsage),
                        symbol: "memorychip",
                        detail: "\(DisplayFormat.bytes(gpu.memoryUsedBytes)) / \(DisplayFormat.bytes(gpu.memoryTotalBytes))"
                    )
                    MonitorStatTile(
                        title: "温度",
                        value: gpu.temperatureCelsius.map {
                            DisplayFormat.decimal($0, fractionLength: 0) + "°C"
                        } ?? "—",
                        symbol: "thermometer.medium",
                        tint: (gpu.temperatureCelsius ?? 0) >= 85 ? .appError : .appWarning
                    )
                    MonitorStatTile(
                        title: "风扇",
                        value: gpu.fanPercent.map(DisplayFormat.percent) ?? "—",
                        symbol: "fan"
                    )
                    MonitorStatTile(
                        title: "功耗",
                        value: gpu.powerWatts.map {
                            DisplayFormat.decimal($0, fractionLength: 1) + " W"
                        } ?? "—",
                        symbol: "bolt.fill",
                        detail: gpu.powerLimitWatts.map {
                            "上限 \(DisplayFormat.decimal($0, fractionLength: 1)) W"
                        }
                    )
                }
            }

            if !processes.isEmpty {
                Divider()
                Text("GPU 进程")
                    .font(.callout.weight(.semibold))
                ForEach(processes) { process in
                    HStack {
                        Text("\(process.pid)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(process.name).lineLimit(1)
                        Spacer()
                        Text(DisplayFormat.bytes(process.memoryBytes))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
        }
    }
}

struct DockerDashboardDetailView: View {
    let snapshot: ServerSnapshot

    @State private var searchText = ""
    @State private var filter: DockerStateFilter = .all

    private var summary: DockerStatusSummary {
        MonitorPresentation.dockerSummary(snapshot.dockerContainers)
    }

    private var rows: [DockerContainerMetric] {
        MonitorPresentation.dockerContainers(
            snapshot.dockerContainers,
            searchText: searchText,
            filter: filter
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170))],
                spacing: AppleDesign.Spacing.sm
            ) {
                MonitorStatTile(
                    title: "容器总数",
                    value: DisplayFormat.integer(summary.total),
                    symbol: "shippingbox"
                )
                MonitorStatTile(
                    title: "运行中",
                    value: DisplayFormat.integer(summary.running),
                    symbol: "play.circle.fill",
                    tint: .appLive
                )
                MonitorStatTile(
                    title: "已停止",
                    value: DisplayFormat.integer(summary.stopped),
                    symbol: "stop.circle",
                    tint: .secondary
                )
                MonitorStatTile(
                    title: "Docker",
                    value: snapshot.dockerVersion.isEmpty ? "—" : snapshot.dockerVersion,
                    symbol: "shippingbox.fill"
                )
            }
            .padding(AppleDesign.Spacing.md)

            Divider()

            HStack {
                TextField("搜索容器、镜像或状态", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 340)
                Spacer()
                Picker("状态", selection: $filter) {
                    ForEach(DockerStateFilter.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }
            .padding(AppleDesign.Spacing.md)

            if rows.isEmpty {
                MonitorDetailEmptyState(
                    title: snapshot.dockerContainers.isEmpty ? "没有容器" : "没有匹配的容器",
                    description: snapshot.dockerContainers.isEmpty
                        ? "Docker 当前没有已创建的容器。"
                        : "尝试其他搜索词或状态筛选。",
                    symbol: "shippingbox"
                )
            } else {
                Table(rows) {
                    TableColumn("名称") {
                        Text($0.name).fontWeight(.medium)
                    }
                    TableColumn("镜像") {
                        Text($0.image).lineLimit(1)
                    }
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
                    TableColumn("详情") {
                        Text($0.status)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

struct ResourceUsageRing: View {
    let value: Double
    let title: String
    let symbol: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.appTrack, lineWidth: 12)
            Circle()
                .trim(from: 0, to: min(1, max(0, value / 100)))
                .stroke(
                    MonitorSeverity.percentage(value).color,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: AppleDesign.Spacing.xxs) {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                Text(DisplayFormat.percent(value))
                    .font(.title2.monospacedDigit().weight(.bold))
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 132, height: 132)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(DisplayFormat.percent(value))
    }
}

struct MonitorDetailEmptyState: View {
    let title: String
    let description: String
    let symbol: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(description)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

enum NetworkFormat {
    static func speed(_ bytesPerSecond: Double, bits: Bool) -> String {
        "\(bytes(bytesPerSecond, bits: bits))/s"
    }

    static func bytes(_ value: Double, bits: Bool) -> String {
        guard bits else { return DisplayFormat.bytes(value) }
        let bitsValue = max(0, value) * 8
        let units = ["b", "Kb", "Mb", "Gb", "Tb"]
        var scaled = bitsValue
        var index = 0
        while scaled >= 1000, index < units.count - 1 {
            scaled /= 1000
            index += 1
        }
        return "\(DisplayFormat.decimal(scaled, fractionLength: scaled < 10 ? 1 : 0)) \(units[index])"
    }
}
