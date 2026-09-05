import SwiftUI

struct AppSidebar: View {
    @EnvironmentObject private var appState: AppState

    let selection: SidebarDestination
    let terminalCount: Int
    let onNavigate: (SidebarDestination) -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppleDesign.Spacing.sm) {
                Image(systemName: "server.rack")
                    .font(.title2.weight(.medium))
                    .frame(width: 36, height: 36)
                    .background(Color.appSurface, in: RoundedRectangle(cornerRadius: AppleDesign.Radius.thumbnail))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ServerDash").font(.headline)
                    Text("服务器工作台").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(AppleDesign.Spacing.md)

            List(selection: selectionBinding) {
                Section("工作区") {
                    Label("仪表盘", systemImage: "gauge.with.dots.needle.50percent")
                        .tag(SidebarDestination.dashboard)
                    Label("机器", systemImage: "server.rack")
                        .tag(SidebarDestination.machines)
                    Label("终端会话", systemImage: "terminal")
                        .badge(terminalCount)
                        .tag(SidebarDestination.terminal)
                }

                Section("资源") {
                    Label("身份", systemImage: "person.crop.circle.badge.checkmark")
                        .tag(SidebarDestination.identities)
                    Label("SSH 密钥", systemImage: "key")
                        .tag(SidebarDestination.sshKeys)
                    Label("代码片段", systemImage: "curlybraces")
                        .tag(SidebarDestination.snippets)
                }

                Section("连接与安全") {
                    Label("可信主机", systemImage: "checkmark.shield")
                        .tag(SidebarDestination.trustedHosts)
                    Label("连接与隧道", systemImage: "point.3.connected.trianglepath.dotted")
                        .tag(SidebarDestination.connections)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 36)
            .scrollContentBackground(.hidden)

            Divider().padding(.horizontal, AppleDesign.Spacing.md)
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
                HStack {
                    Label(
                        appState.refreshInterval > 0 ? "自动刷新" : "手动刷新",
                        systemImage: appState.refreshInterval > 0 ? "arrow.clockwise" : "pause.circle"
                    )
                    Spacer(minLength: 0)
                    if appState.refreshInterval > 0 {
                        Text("\(DisplayFormat.integer(Int(appState.refreshInterval))) 秒")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Button(action: onSettings) {
                    HStack {
                        Label("设置", systemImage: "gearshape")
                        Spacer()
                        Text("⌘,").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .help("打开设置")
            }
            .buttonStyle(.borderless)
            .padding(AppleDesign.Spacing.md)
        }
        .background(AppleChromeBackground())
    }

    private var selectionBinding: Binding<SidebarDestination?> {
        Binding(
            get: { selection },
            set: { destination in
                if let destination {
                    onNavigate(destination)
                }
            }
        )
    }
}

struct ServerBrowserControls: View {
    let servers: [ServerRecord]
    @Binding var search: String
    @Binding var group: String
    @Binding var tag: String
    @Binding var sortRawValue: String

    private var groups: [String] {
        Set(servers.map(\.groupName).filter { !$0.isEmpty }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var tags: [String] {
        Set(servers.flatMap(\.tags)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack(spacing: AppleDesign.Spacing.sm) {
                AppleSearchField(prompt: "搜索服务器、地址或标签", text: $search)
                    .frame(maxWidth: .infinity)
                Menu {
                    Picker("分组", selection: $group) {
                        Text("全部分组").tag("")
                        ForEach(groups, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label(group.isEmpty ? "全部分组" : group, systemImage: "folder")
                        .lineLimit(1)
                }
                .frame(maxWidth: 150)
                .help(group.isEmpty ? "按分组筛选服务器" : group)
                Menu {
                    Picker("排序", selection: $sortRawValue) {
                        ForEach(ServerBrowserSort.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .fixedSize()
                .help("排序：\((ServerBrowserSort(rawValue: sortRawValue) ?? .name).title)")
                .accessibilityLabel("服务器排序")
            }
            if !tags.isEmpty || !tag.isEmpty || !group.isEmpty {
                HStack(spacing: AppleDesign.Spacing.sm) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppleDesign.Spacing.xs) {
                            tagButton("全部标签", value: "")
                            ForEach(tags, id: \.self) { tagButton($0, value: $0) }
                        }
                        .padding(.vertical, AppleDesign.Spacing.xxs)
                    }
                    if !tag.isEmpty || !group.isEmpty {
                        Button("重置") { group = ""; tag = "" }
                            .buttonStyle(.borderless)
                            .help("清除分组和标签筛选")
                    }
                }
            }
        }
    }

    private func tagButton(_ title: String, value: String) -> some View {
        Button { tag = value } label: {
            Text(title)
                .font(.caption.weight(tag == value ? .semibold : .regular))
                .foregroundStyle(tag == value ? Color.accentColor : .secondary)
                .padding(.horizontal, AppleDesign.Spacing.sm)
                .padding(.vertical, AppleDesign.Spacing.xs)
                .background(tag == value ? Color.accentColor.opacity(0.1) : Color.appSurface,
                            in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.isEmpty ? "显示全部标签" : "筛选标签：\(title)")
        .accessibilityAddTraits(tag == value ? .isSelected : [])
    }
}

enum MachineViewMode: String, CaseIterable, Identifiable {
    case list
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: "列表"
        case .grid: "宫格"
        }
    }

    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.3x3"
        }
    }
}

struct MachineManagementView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("machineViewMode") private var viewModeRawValue = MachineViewMode.grid.rawValue
    @SceneStorage("machines.filter.group") private var selectedGroup = ""
    @SceneStorage("machines.filter.tag") private var selectedTag = ""
    @SceneStorage("machines.sort") private var sortRawValue = ServerBrowserSort.name.rawValue

    let servers: [ServerRecord]
    @Binding var searchText: String
    @Binding var scrollAnchor: UUID?
    let onSelect: (ServerRecord) -> Void
    let onAdd: () -> Void
    let onEdit: (ServerRecord) -> Void
    let onDelete: (ServerRecord) -> Void

    private var query: ServerBrowserQuery {
        ServerBrowserQuery(search: searchText, group: selectedGroup, tag: selectedTag,
                           sort: ServerBrowserSort(rawValue: sortRawValue) ?? .name)
    }

    private var visibleServers: [ServerRecord] { query.apply(to: servers) }

    private var viewMode: MachineViewMode {
        MachineViewMode(rawValue: viewModeRawValue) ?? .grid
    }

    private var viewModeBinding: Binding<MachineViewMode> {
        Binding(
            get: { viewMode },
            set: { viewModeRawValue = $0.rawValue }
        )
    }

    private var columns: [GridItem] {
        switch viewMode {
        case .list:
            [GridItem(.flexible(), spacing: 0)]
        case .grid:
            [GridItem(.adaptive(minimum: 280), spacing: AppleDesign.Spacing.md)]
        }
    }

    private var scrollPosition: Binding<UUID?> {
        Binding(
            get: { scrollAnchor },
            set: { id in
                // Disappearing content must not clear the return position saved by navigation.
                if let id { scrollAnchor = id }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: AppleDesign.Spacing.md) {
                AppleWorkspaceHeader(
                    title: "机器", subtitle: "管理连接，随时进入你的服务器。", symbol: "server.rack"
                ) {
                    Button("添加服务器", systemImage: "plus", action: onAdd)
                        .buttonStyle(.borderedProminent)
                }
                HStack(spacing: AppleDesign.Spacing.md) {
                    Text("\(DisplayFormat.integer(visibleServers.count)) / \(DisplayFormat.integer(servers.count)) 台服务器")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Picker("显示方式", selection: viewModeBinding) {
                        ForEach(MachineViewMode.allCases) { mode in
                            Image(systemName: mode.symbol)
                                .accessibilityLabel(mode.title)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 84)
                    .help("切换列表或网格")
                    .accessibilityLabel("机器显示方式")
                }
                ServerBrowserControls(
                    servers: servers, search: $searchText, group: $selectedGroup,
                    tag: $selectedTag, sortRawValue: $sortRawValue
                )
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: AppleDesign.Layout.contentWidth)
            .frame(maxWidth: .infinity)

            Divider().opacity(0.5)

            if visibleServers.isEmpty {
                ContentUnavailableView {
                    Label(
                        query.hasFilters ? "没有匹配的机器" : "还没有机器",
                        systemImage: "externaldrive"
                    )
                } description: {
                    Text(query.hasFilters ? "试试其他关键词、分组或标签。" : "添加服务器后可在这里统一管理。")
                } actions: {
                    if query.hasFilters {
                        Button("清除筛选") { clearFilters() }
                    } else {
                        Button("添加服务器", action: onAdd)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // A shared scroll container and stable targets preserve the visible machine
                    // when the grid reflows, including its single-column list presentation.
                    LazyVGrid(
                        columns: columns,
                        spacing: viewMode == .grid ? AppleDesign.Spacing.md : 0
                    ) {
                        ForEach(visibleServers) { server in
                            VStack(spacing: 0) {
                                machineButton(server)
                                if viewMode == .list, server.id != visibleServers.last?.id {
                                    Divider()
                                        .padding(.horizontal, AppleDesign.Spacing.md)
                                }
                            }
                            .id(server.id)
                        }
                    }
                    .scrollTargetLayout()
                    .background {
                        if viewMode == .list {
                            RoundedRectangle(cornerRadius: AppleDesign.Radius.panel, style: .continuous)
                                .fill(Color.appSurface)
                        }
                    }
                    .padding(AppleDesign.Spacing.lg)
                    .frame(maxWidth: AppleDesign.Layout.contentWidth)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition(id: scrollPosition, anchor: .top)
            }
        }
        .onChange(of: visibleServers.map(\.id)) { _, ids in
            if let scrollAnchor, !ids.contains(scrollAnchor) { self.scrollAnchor = ids.first }
        }
    }

    private func clearFilters() {
        searchText = ""
        selectedGroup = ""
        selectedTag = ""
    }

    private func machineButton(_ server: ServerRecord) -> some View {
        Button {
            onSelect(server)
        } label: {
            if viewMode == .grid {
                MachineGridCard(server: server, runtime: appState.runtime(for: server))
            } else {
                MachineListRow(server: server, runtime: appState.runtime(for: server))
            }
        }
        .buttonStyle(.plain)
        .appleInteractiveSurface(radius: viewMode == .grid ? AppleDesign.Radius.card : AppleDesign.Radius.chip)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开机器监控详情")
        .contextMenu {
            Button("编辑服务器", systemImage: "pencil") {
                onEdit(server)
            }
            Divider()
            Button("删除服务器", systemImage: "trash", role: .destructive) {
                onDelete(server)
            }
        }
    }
}

private struct MachineGridCard: View {
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    let server: ServerRecord
    @ObservedObject var runtime: ServerRuntimeState

    private var status: ServerConnectionStatus { runtime.renderState.status }
    private var snapshot: ServerSnapshot { runtime.renderState.snapshot }
    private var connectionAddress: String { "\(server.username)@\(hideIPInformation ? "[IP]" : server.host):\(server.port)" }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
                ServerStatusBadge(status: status)
            }
            HStack(spacing: AppleDesign.Spacing.xs) {
                Text(server.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .help(server.displayName)
                Spacer(minLength: AppleDesign.Spacing.xs)
            }

            Text(connectionAddress)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(connectionAddress)

            Label(server.groupName, systemImage: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(server.groupName)

            if !server.tags.isEmpty {
                Label(server.tags.joined(separator: " · "), systemImage: "tag")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(server.tags.joined(separator: " · "))
            }

            Divider()

            HStack(spacing: AppleDesign.Spacing.sm) {
                metric("CPU", value: snapshot.cpuUsage)
                metric("内存", value: snapshot.memoryUsage)
                metric("磁盘", value: snapshot.diskUsage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .applePanel(radius: AppleDesign.Radius.card)
        .contentShape(RoundedRectangle(cornerRadius: AppleDesign.Radius.card, style: .continuous))
    }

    private func metric(_ title: String, value: Double) -> some View {
        MachineMetric(
            title: title,
            value: runtime.renderState.hasSnapshot ? DisplayFormat.percent(value) : "—",
            alignment: .leading,
            expands: true
        )
    }
}

private struct MachineListRow: View {
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    let server: ServerRecord
    @ObservedObject var runtime: ServerRuntimeState

    private var status: ServerConnectionStatus { runtime.renderState.status }
    private var snapshot: ServerSnapshot { runtime.renderState.snapshot }

    var body: some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            StatusDot(status: status, size: 9)
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                Text(server.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .help(server.displayName)
                Text("\(server.username)@\(hideIPInformation ? "[IP]" : server.host):\(server.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(server.username)@\(hideIPInformation ? "[IP]" : server.host):\(server.port)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(server.groupName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(server.groupName)
                .padding(.horizontal, AppleDesign.Spacing.xs)
                .padding(.vertical, AppleDesign.Spacing.xxs)
                .background(Color.appTrack)
                .clipShape(Capsule())
                .frame(width: 100)
            MachineMetric(
                title: "CPU",
                value: runtime.renderState.hasSnapshot
                    ? DisplayFormat.percent(snapshot.cpuUsage)
                    : "—"
            )
            MachineMetric(
                title: "内存",
                value: runtime.renderState.hasSnapshot
                    ? DisplayFormat.percent(snapshot.memoryUsage)
                    : "—"
            )
            MachineMetric(
                title: "磁盘",
                value: runtime.renderState.hasSnapshot
                    ? DisplayFormat.percent(snapshot.diskUsage)
                    : "—"
            )
            Text(status.title)
                .font(.caption2.weight(.semibold))
                .fixedSize()
                .frame(minWidth: 55, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption2.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, AppleDesign.Spacing.md)
        .padding(.vertical, AppleDesign.Spacing.sm)
        .contentShape(Rectangle())
    }
}

private struct MachineMetric: View {
    let title: String
    let value: String
    var alignment: HorizontalAlignment = .trailing
    var expands = false

    var body: some View {
        VStack(alignment: alignment, spacing: AppleDesign.Spacing.xxs) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .frame(width: expands ? nil : 46, alignment: Alignment(horizontal: alignment, vertical: .center))
        .frame(maxWidth: expands ? .infinity : nil, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
    }
}

struct TerminalSessionsLandingView: View {
    @AppStorage("hideIPInformation") private var hideIPInformation = false
    let sessions: [TerminalSession]
    let onOpen: (TerminalSession) -> Void
    let onChooseServer: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                AppleWorkspaceHeader(
                    title: "终端会话",
                    subtitle: "\(DisplayFormat.integer(sessions.count)) 个会话 · 切换页面后仍保持连接",
                    symbol: "terminal"
                ) {
                    Button("选择机器", systemImage: "plus", action: onChooseServer)
                        .buttonStyle(.borderedProminent)
                }
                if sessions.isEmpty {
                    ContentUnavailableView {
                        Label("开始一个终端会话", systemImage: "terminal")
                    } description: {
                        Text("选择一台服务器以建立 SSH 连接。\n使用 ⌘T 新建标签页，⌃Tab 切换会话。")
                    } actions: {
                        Button("选择机器", action: onChooseServer)
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .applePanel()
                } else {
                    AppleUnifiedPanel {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            Button { onOpen(session) } label: {
                                HStack(spacing: AppleDesign.Spacing.md) {
                                    Image(systemName: "terminal")
                                        .font(.title3)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 36, height: 36)
                                        .background(Color.appGround, in: RoundedRectangle(cornerRadius: AppleDesign.Radius.chip))
                                    VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                                        Text(session.serverName)
                                            .font(.headline).lineLimit(1)
                                        Text("\(session.config.username)@\(hideIPInformation ? "[IP]" : session.config.host)")
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Text(session.status.title)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(statusColor(session.status))
                                        .fixedSize()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(AppleDesign.Spacing.md)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .appleInteractiveSurface(radius: AppleDesign.Radius.chip)
                            .accessibilityElement(children: .combine)
                            .accessibilityHint("切换到此终端会话")
                            if index < sessions.count - 1 {
                                Divider().padding(.leading, 68)
                            }
                        }
                    }
                }
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: AppleDesign.Layout.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func statusColor(_ status: TerminalConnectionStatus) -> Color {
        switch status {
        case .connected: .appLive
        case .connecting: .appWarning
        case .failed: .appError
        case .disconnected: .secondary
        }
    }
}
