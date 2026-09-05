import SwiftData
import SwiftUI

struct MobileDashboardView: View {
    @EnvironmentObject private var runtime: MobileRuntime
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]
    @Query private var identities: [IdentityRecord]
    @Query private var keys: [SSHKeyRecord]
    @Query private var routes: [ConnectionRouteRecord]
    @SceneStorage("mobile.dashboard.search") private var search = ""
    @SceneStorage("mobile.dashboard.group") private var group = ""
    @SceneStorage("mobile.dashboard.tag") private var tag = ""
    @SceneStorage("mobile.dashboard.sort") private var sort = ServerBrowserSort.name.rawValue
    @SceneStorage("mobile.dashboard.monitoring") private var monitoring = ServerMonitorFilter.all.rawValue
    @State private var showingNewServer = false
    @AppStorage("mobileRefreshInterval") private var refreshInterval = 15

    private var query: ServerBrowserQuery {
        ServerBrowserQuery(search: search, group: group, tag: tag,
                           sort: ServerBrowserSort(rawValue: sort) ?? .name,
                           monitoring: ServerMonitorFilter(rawValue: monitoring) ?? .all)
    }

    var body: some View {
        let visibleServers = query.apply(to: servers)
        let summary = MobileFleetSummary(servers: servers, statuses: runtime.statuses)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("服务器概览").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    Text("共 \(servers.count) 台 · \(summary.paused) 台暂停监控")
                        .font(.subheadline).foregroundStyle(.secondary)
                    (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                     : AnyLayout(HStackLayout(spacing: 12))) { summaryItems(summary) }
                    if !runtime.refreshingServerIDs.isEmpty {
                        Label("\(runtime.refreshingServerIDs.count) 台正在刷新或排队", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label(refreshInterval > 0 ? "前台自动刷新" : "手动刷新", systemImage: refreshInterval > 0 ? "clock" : "pause.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if summary.issues > 0 {
                        Button("重试异常机器", systemImage: "arrow.clockwise") {
                            Task { await refreshAll(failedOnly: true) }
                        }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                        .disabled(runtime.isBackgrounded || !runtime.refreshingServerIDs.isEmpty)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [Color.appAccent.opacity(0.15), .appSurface],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 24))

                if servers.isEmpty {
                    ContentUnavailableView {
                        Label("连接你的第一台服务器", systemImage: "server.rack")
                    } description: {
                        Text("添加服务器后，即可查看监控、打开终端和管理文件。")
                    } actions: {
                        Button("添加服务器", systemImage: "plus") { showingNewServer = true }
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                    }
                } else {
                    HStack {
                        Text(query.hasFilters ? "匹配 \(visibleServers.count) / \(servers.count) 台" : "全部机器")
                            .font(.headline)
                        Spacer()
                        MobileServerBrowserMenu(servers: servers, group: $group, tag: $tag, sort: $sort,
                                                monitoring: $monitoring, hasFilters: query.hasFilters, clear: clearFilters)
                    }
                    if visibleServers.isEmpty {
                        ContentUnavailableView {
                            Label("没有匹配的服务器", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("试试其他关键词，或清除筛选。")
                        } actions: {
                            Button("清除筛选", action: clearFilters).frame(minHeight: 44)
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(sizeClass == .regular && !typeSize.isAccessibilitySize
                                                    ? .adaptive(minimum: 320) : .flexible(), spacing: 16)], spacing: 16) {
                            ForEach(visibleServers) { server in
                                NavigationLink { MobileServerDetailView(server: server) } label: {
                                    MobileServerStatusCard(server: server, snapshot: runtime.snapshots[server.id],
                                                           status: runtime.statuses[server.id] ?? .unknown,
                                                           error: runtime.errors[server.id],
                                                           isRefreshing: runtime.refreshingServerIDs.contains(server.id))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .background(Color.appGround)
        .navigationTitle("仪表盘")
        .searchable(text: $search, prompt: "名称、地址、标签或备注")
        .refreshable { await refreshAll() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await refreshAll() } } label: {
                    Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("刷新全部监控").keyboardShortcut("r", modifiers: .command)
                .disabled(runtime.isBackgrounded || !runtime.refreshingServerIDs.isEmpty)
                Button { showingNewServer = true } label: {
                    Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("添加服务器")
            }
        }
        .sheet(isPresented: $showingNewServer) { MobileServerEditor(server: nil) }
    }

    private func summaryItems(_ summary: MobileFleetSummary) -> some View {
        Group {
            summaryItem("在线", value: summary.online, symbol: "checkmark.circle.fill", color: .appLive)
            summaryItem("需关注", value: summary.issues, symbol: "exclamationmark.circle.fill", color: summary.issues > 0 ? .appError : .secondary)
            summaryItem("待检测", value: summary.pending, symbol: "clock", color: .secondary)
        }
    }

    private func summaryItem(_ title: String, value: Int, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color)
            Text(value, format: .number).font(.title.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func refreshAll(failedOnly: Bool = false) async {
        await runtime.refreshAll(servers: servers, identities: identities, keys: keys, routes: routes, failedOnly: failedOnly)
    }

    private func clearFilters() { search = ""; group = ""; tag = ""; monitoring = "all" }
}

struct MobileServerBrowserMenu: View {
    let servers: [ServerRecord]
    @Binding var group: String
    @Binding var tag: String
    @Binding var sort: String
    @Binding var monitoring: String
    let hasFilters: Bool
    let clear: () -> Void

    var body: some View {
        Menu {
            Picker("分组", selection: $group) {
                Text("全部分组").tag("")
                ForEach(Set(servers.map(\.groupName)).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Picker("标签", selection: $tag) {
                Text("全部标签").tag("")
                ForEach(Set(servers.flatMap(\.tags)).sorted(), id: \.self) { Text($0).tag($0) }
            }
            Picker("监控", selection: $monitoring) {
                ForEach(ServerMonitorFilter.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("排序", selection: $sort) {
                ForEach(ServerBrowserSort.allCases) { Text($0.title).tag($0.rawValue) }
            }
            if hasFilters { Button("清除筛选", systemImage: "xmark.circle", action: clear) }
        } label: {
            Label(hasFilters ? "已筛选" : "筛选与排序", systemImage: hasFilters
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.subheadline).frame(minHeight: 44)
        }
    }
}

struct MobileServerStatusCard: View {
    let server: ServerRecord
    let snapshot: ServerSnapshot?
    let status: ServerConnectionStatus
    let error: String?
    var isRefreshing = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    @AppStorage("mobileRefreshInterval") private var refreshInterval = 15

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
             : AnyLayout(HStackLayout(spacing: 12))) {
                Image(systemName: "server.rack")
                    .font(.system(size: 20)).foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Color.appAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hideIPInformation && server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "未命名服务器" : server.displayName).font(.headline).lineLimit(2)
                    Text(hideIPInformation ? "[地址已隐藏]" : "\(server.username)@\(server.host):\(server.port)")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Label(server.enableDashboardMonitor ? status.title : "已暂停", systemImage: statusSymbol)
                    .font(.caption.weight(.semibold)).foregroundStyle(statusColor)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(statusColor.opacity(0.1), in: Capsule())
            }
            if let snapshot {
                (typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))) {
                    metric("CPU", snapshot.cpuUsage)
                    metric("内存", snapshot.memoryUsage)
                    metric("磁盘", snapshot.diskUsage)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { networkMetrics(snapshot) }
                    VStack(alignment: .leading, spacing: 8) { networkMetrics(snapshot) }
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let stale = context.date.timeIntervalSince(snapshot.capturedAt) > Double(max(45, refreshInterval * 3))
                    Label {
                        if stale || status == .failed || status == .offline {
                            Text("数据已过期 · 保留上次结果")
                        } else {
                            Text("更新于 \(snapshot.capturedAt.formatted(date: .omitted, time: .shortened))")
                        }
                    } icon: { Image(systemName: stale ? "clock.badge.exclamationmark" : "clock") }
                    .font(.caption).foregroundStyle(stale ? Color.appWarning : .secondary)
                }
            } else {
                Label(server.enableDashboardMonitor ? (isRefreshing ? "正在采集资源…" : "等待首次监控采集") : "自动监控已暂停，可手动刷新",
                      systemImage: isRefreshing ? "arrow.triangle.2.circlepath" : "clock")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let error {
                Label(hideIPInformation ? "连接失败，请检查连接配置后重试。" : error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Color.appError).lineLimit(3)
            }
            HStack {
                Label(server.groupName, systemImage: "folder").lineLimit(1)
                Spacer(minLength: 8)
                if isRefreshing { ProgressView().controlSize(.small).accessibilityLabel("正在刷新") }
                Image(systemName: "chevron.right").accessibilityHidden(true)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .applePanel(padding: 18, radius: 20)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        guard server.enableDashboardMonitor else { return .secondary }
        switch status {
        case .online: return .appLive
        case .failed, .offline: return .appError
        case .connecting: return .appAccent
        case .unknown: return .secondary
        }
    }

    private var statusSymbol: String {
        guard server.enableDashboardMonitor else { return "pause.circle" }
        switch status {
        case .online: return "checkmark.circle"
        case .failed, .offline: return "exclamationmark.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .unknown: return "clock"
        }
    }

    private func networkMetrics(_ snapshot: ServerSnapshot) -> some View {
        Group {
            Label(DisplayFormat.speed(snapshot.downloadBytesPerSecond), systemImage: "arrow.down")
                .accessibilityLabel("下载 \(DisplayFormat.speed(snapshot.downloadBytesPerSecond))")
            Label(DisplayFormat.speed(snapshot.uploadBytesPerSecond), systemImage: "arrow.up")
                .accessibilityLabel("上传 \(DisplayFormat.speed(snapshot.uploadBytesPerSecond))")
        }
    }

    private func metric(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(DisplayFormat.percent(value)).font(.title3.weight(.semibold)).monospacedDigit()
            MonitorLinearGauge(value: value).accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
