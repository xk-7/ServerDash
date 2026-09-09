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
                    Label("会话", systemImage: "rectangle.stack")
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
                    Label("录制", systemImage: "record.circle")
                        .tag(SidebarDestination.recordings)
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
    var additionalGroups: [String] = []
    var additionalTags: [String] = []
    @Binding var search: String
    @Binding var group: String
    @Binding var tag: String
    @Binding var sortRawValue: String
    @Binding var monitoringRawValue: String

    private var groups: [String] {
        Set((servers.map(\.groupName) + additionalGroups).filter { !$0.isEmpty }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var tags: [String] {
        Set(servers.flatMap(\.tags) + additionalTags).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack(spacing: AppleDesign.Spacing.sm) {
                AppleSearchField(prompt: "搜索名称、地址、标签或备注（空格组合）", text: $search)
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
                    Picker("监控范围", selection: $monitoringRawValue) {
                        ForEach(ServerMonitorFilter.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                } label: {
                    Label((ServerMonitorFilter(rawValue: monitoringRawValue) ?? .all).title,
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .help("按监控开关筛选；不改变采集设置")
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
            if !tags.isEmpty || !tag.isEmpty || !group.isEmpty || !search.isEmpty || monitoringRawValue != "all" {
                HStack(spacing: AppleDesign.Spacing.sm) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppleDesign.Spacing.xs) {
                            tagButton("全部标签", value: "")
                            ForEach(tags, id: \.self) { tagButton($0, value: $0) }
                        }
                        .padding(.vertical, AppleDesign.Spacing.xxs)
                    }
                    if !tag.isEmpty || !group.isEmpty || !search.isEmpty || monitoringRawValue != "all" {
                        Button("重置") { group = ""; tag = ""; search = ""; monitoringRawValue = "all" }
                            .buttonStyle(.borderless)
                            .help("清除全部筛选")
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
