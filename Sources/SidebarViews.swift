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
                }

                Section("终端") {
                    Label(
                        terminalCount == 0 ? "无会话" : "\(terminalCount) 个会话",
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
                Text(appState.refreshInterval > 0 ? "\(Int(appState.refreshInterval))s" : "手动")
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

struct MachineManagementView: View {
    @EnvironmentObject private var appState: AppState

    let servers: [ServerRecord]
    @Binding var searchText: String
    let onSelect: (ServerRecord) -> Void
    let onAdd: () -> Void
    let onEdit: (ServerRecord) -> Void
    let onDelete: (ServerRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("机器")
                        .font(.system(size: 22, weight: .bold))
                    Text("\(servers.count) 台服务器")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider().opacity(0.5)

            if servers.isEmpty {
                ContentUnavailableView {
                    Label("没有匹配的机器", systemImage: "externaldrive")
                } description: {
                    Text(searchText.isEmpty ? "添加服务器后可在这里统一管理。" : "请尝试其他搜索关键词。")
                } actions: {
                    if searchText.isEmpty {
                        Button("添加服务器", action: onAdd)
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                List(servers) { server in
                    Button {
                        onSelect(server)
                    } label: {
                        MachineListRow(
                            server: server,
                            status: appState.status(for: server),
                            snapshot: appState.snapshot(for: server)
                        )
                    }
                    .buttonStyle(.plain)
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
                .listStyle(.inset)
            }
        }
    }
}

private struct MachineListRow: View {
    let server: ServerRecord
    let status: ServerConnectionStatus
    let snapshot: ServerSnapshot

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(status: status, size: 9)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.headline)
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(server.groupName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05))
                .clipShape(Capsule())
            MachineMetric(title: "CPU", value: DisplayFormat.percent(snapshot.cpuUsage))
            MachineMetric(title: "内存", value: DisplayFormat.percent(snapshot.memoryUsage))
            MachineMetric(title: "磁盘", value: DisplayFormat.percent(snapshot.diskUsage))
            Text(status.title)
                .font(.caption2.weight(.semibold))
                .frame(width: 55, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.caption2.bold())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }
}

private struct MachineMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(width: 46, alignment: .trailing)
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
                    subtitle: "\(sessions.count) 个正在运行的 SSH 会话"
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
