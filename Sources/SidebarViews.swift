import SwiftUI

struct AppSidebar: View {
    @EnvironmentObject private var appState: AppState

    let selection: SidebarDestination
    let terminalCount: Int
    let onNavigate: (SidebarDestination) -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {
                Label("仪表板", systemImage: "gauge")
                    .tag(SidebarDestination.dashboard)

                Section("资源") {
                    Label("机器", systemImage: "externaldrive")
                        .tag(SidebarDestination.machines)
                    Label("身份", systemImage: "person.crop.circle.badge.checkmark")
                        .tag(SidebarDestination.identities)
                    Label("SSH 密钥", systemImage: "key")
                        .tag(SidebarDestination.sshKeys)
                    Label("代码片段", systemImage: "curlybraces")
                        .tag(SidebarDestination.snippets)
                    Label("可信主机", systemImage: "checkmark.shield")
                        .tag(SidebarDestination.trustedHosts)
                    Label("连接与隧道", systemImage: "point.3.connected.trianglepath.dotted")
                        .tag(SidebarDestination.connections)
                }

                Section("终端") {
                    Label(
                        terminalCount == 0 ? "无会话" : "\(DisplayFormat.integer(terminalCount)) 个会话",
                        systemImage: "rectangle.dashed"
                    )
                    .tag(SidebarDestination.terminal)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            HStack(spacing: AppleDesign.Spacing.xs) {
                Button(action: onSettings) {
                    Label("设置", systemImage: "gearshape")
                }
                .help("设置")
                Spacer()
                Text(appState.refreshInterval > 0 ? "\(DisplayFormat.integer(Int(appState.refreshInterval)))s" : "手动")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .padding(12)
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

    let servers: [ServerRecord]
    @Binding var searchText: String
    @Binding var scrollAnchor: UUID?
    let onSelect: (ServerRecord) -> Void
    let onAdd: () -> Void
    let onEdit: (ServerRecord) -> Void
    let onDelete: (ServerRecord) -> Void

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
            HStack(spacing: AppleDesign.Spacing.sm) {
                AppleSectionHeader(
                    title: "机器",
                    subtitle: "\(DisplayFormat.integer(servers.count)) 台服务器"
                )
                Spacer()
                Picker("显示方式", selection: viewModeBinding) {
                    ForEach(MachineViewMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("切换机器的列表或宫格视图")
                .accessibilityLabel("机器显示方式")
            }
            .padding(AppleDesign.Spacing.lg)

            Divider().opacity(0.5)

            if servers.isEmpty {
                ContentUnavailableView {
                    Label(
                        searchText.isEmpty ? "还没有机器" : "没有匹配的机器",
                        systemImage: "externaldrive"
                    )
                } description: {
                    Text(searchText.isEmpty ? "添加服务器后可在这里统一管理。" : "请尝试其他搜索关键词。")
                } actions: {
                    if searchText.isEmpty {
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
                        ForEach(servers) { server in
                            VStack(spacing: 0) {
                                machineButton(server)
                                if viewMode == .list, server.id != servers.last?.id {
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
                }
                .scrollPosition(id: scrollPosition, anchor: .top)
            }
        }
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
    let server: ServerRecord
    @ObservedObject var runtime: ServerRuntimeState

    private var status: ServerConnectionStatus { runtime.renderState.status }
    private var snapshot: ServerSnapshot { runtime.renderState.snapshot }
    private var connectionAddress: String { "\(server.username)@\(server.host):\(server.port)" }

    var body: some View {
        VStack(alignment: .leading, spacing: AppleDesign.Spacing.sm) {
            HStack(spacing: AppleDesign.Spacing.xs) {
                Text(server.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .help(server.displayName)
                Spacer(minLength: AppleDesign.Spacing.xs)
                HStack(spacing: AppleDesign.Spacing.xxs) {
                    StatusDot(status: status)
                    Text(status.title)
                        .font(.caption.weight(.medium))
                }
                .fixedSize()
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
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("\(server.username)@\(server.host):\(server.port)")
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
    let sessions: [TerminalSession]
    let onOpen: (TerminalSession) -> Void
    let onChooseServer: () -> Void

    var body: some View {
        if sessions.isEmpty {
            ContentUnavailableView {
                Label("无会话", systemImage: "rectangle.dashed")
            } description: {
                Text("请先选择一台机器并建立 SSH 连接。")
            } actions: {
                Button("选择机器", action: onChooseServer)
                    .buttonStyle(.borderedProminent)
            }
        } else {
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.lg) {
                AppleSectionHeader(
                    title: "终端会话",
                    subtitle: "\(DisplayFormat.integer(sessions.count)) 个正在运行的 SSH 会话"
                )
                AppleUnifiedPanel {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        Button {
                            onOpen(session)
                        } label: {
                            HStack {
                                Image(systemName: "terminal")
                                    .foregroundStyle(Color.appLive)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.serverName)
                                        .fontWeight(.semibold)
                                    Text("\(session.config.username)@\(session.config.host)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(AppleDesign.Spacing.md)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < sessions.count - 1 {
                            Divider().padding(.leading, 48)
                        }
                    }
                }
                Spacer()
            }
            .padding(AppleDesign.Spacing.lg)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}
