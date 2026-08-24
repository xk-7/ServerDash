import AppKit
import SwiftData
import SwiftUI

enum SidebarDestination: String, Identifiable, Hashable {
    case dashboard
    case machines
    case identities
    case sshKeys
    case snippets
    case trustedHosts
    case terminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "仪表盘"
        case .machines: "机器"
        case .identities: "身份"
        case .sshKeys: "SSH 密钥"
        case .snippets: "代码片段"
        case .trustedHosts: "可信主机"
        case .terminal: "终端"
        }
    }
}

enum MainContentRoute: Equatable {
    case section(SidebarDestination)
    case server(id: UUID, origin: SidebarDestination, mode: DetailMode)

    var sidebarDestination: SidebarDestination {
        switch self {
        case .section(let destination):
            destination
        case .server(_, let origin, _):
            origin
        }
    }

    var serverID: UUID? {
        guard case .server(let id, _, _) = self else { return nil }
        return id
    }

    var detailMode: DetailMode? {
        guard case .server(_, _, let mode) = self else { return nil }
        return mode
    }

    var returningToOrigin: MainContentRoute {
        .section(sidebarDestination)
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var appState: AppState
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]
    @Query(sort: \IdentityRecord.name) private var identities: [IdentityRecord]
    @Query(sort: \SSHKeyRecord.name) private var sshKeys: [SSHKeyRecord]

    @State private var searchText = ""
    @State private var showingNewServer = false
    @State private var editingServer: ServerRecord?
    @State private var serverPendingDeletion: ServerRecord?
    @State private var route: MainContentRoute = .section(.dashboard)
    @State private var dashboardScrollAnchor: UUID?
    @State private var machineScrollAnchor: UUID?

    private var filteredServers: [ServerRecord] {
        guard !searchText.isEmpty else { return servers }
        return servers.filter { server in
            [server.name, server.host, server.groupName, server.tagsText]
                .contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var sidebarDestination: SidebarDestination {
        route.sidebarDestination
    }

    private var selectedServer: ServerRecord? {
        guard let serverID = route.serverID else { return nil }
        return servers.first { $0.id == serverID }
    }

    private var detailModeBinding: Binding<DetailMode> {
        Binding(
            get: { route.detailMode ?? appState.detailMode },
            set: { mode in
                guard case .server(let id, let origin, _) = route else { return }
                route = .server(id: id, origin: origin, mode: mode)
                appState.detailMode = mode
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            AppSidebar(
                selection: sidebarDestination,
                terminalCount: appState.terminalSessions.count,
                onNavigate: navigate,
                onSettings: { openSettings() }
            )
            .navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 260)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.appGround)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            if route == .section(.machines) {
                ToolbarItem(placement: .principal) {
                    TextField("搜索机器", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await appState.refreshAll(servers) }
                } label: {
                    Label("刷新全部", systemImage: "arrow.clockwise")
                }
                .help("刷新全部服务器")
                .disabled(servers.isEmpty)
                .keyboardShortcut("r", modifiers: .command)

                Button {
                    showingNewServer = true
                } label: {
                    Label("添加服务器", systemImage: "plus")
                }
                .help("添加服务器")
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(isPresented: $showingNewServer) {
            ServerEditorView(server: nil) { server in
                openServerDetail(
                    server,
                    origin: sidebarDestination,
                    mode: .monitor
                )
            }
        }
        .sheet(item: $editingServer) { server in
            ServerEditorView(server: server)
        }
        .confirmationDialog(
            "删除 \(serverPendingDeletion?.name ?? "服务器")？",
            isPresented: Binding(
                get: { serverPendingDeletion != nil },
                set: { if !$0 { serverPendingDeletion = nil } }
            )
        ) {
            Button("删除服务器", role: .destructive) {
                guard let server = serverPendingDeletion else { return }
                do {
                    try KeychainService.deletePassword(for: server.id)
                    try? KeychainService.deleteSecret(
                        account: KeychainService.passphraseAccount(for: server.id)
                    )
                    appState.removeRuntimeData(for: server.id)
                    modelContext.delete(server)
                    try modelContext.save()
                    if route.serverID == server.id {
                        route = route.returningToOrigin
                    }
                    EventLogStore.shared.append(
                        serverID: server.id,
                        module: .data,
                        message: "已删除服务器配置"
                    )
                } catch {
                    EventLogStore.shared.append(
                        serverID: server.id,
                        module: .data,
                        level: "error",
                        message: "删除服务器失败：\(error.localizedDescription)"
                    )
                }
                serverPendingDeletion = nil
            }
        } message: {
            Text("服务器配置、服务器专用凭据和终端会话都会被移除；共享身份会保留。此操作无法撤销。")
        }
        .task {
            synchronizeIdentityConnections()
            appState.bootstrap(servers: servers, context: modelContext)
        }
        .onChange(of: servers.count) {
            appState.bootstrap(servers: servers, context: modelContext)
        }
        .onChange(of: identities.count) {
            synchronizeIdentityConnections()
        }
        .onChange(of: sshKeys.count) {
            synchronizeIdentityConnections()
        }
        .onChange(of: appState.selectedServerID) { _, serverID in
            guard let serverID,
                  servers.contains(where: { $0.id == serverID }),
                  case .server(_, let origin, _) = route else {
                return
            }
            route = .server(
                id: serverID,
                origin: origin,
                mode: appState.detailMode
            )
        }
        .onChange(of: appState.detailMode) { _, mode in
            guard case .server(let id, let origin, let currentMode) = route,
                  currentMode != mode else {
                return
            }
            route = .server(id: id, origin: origin, mode: mode)
        }
        .onChange(of: servers.map(\.id)) { _, serverIDs in
            guard let serverID = route.serverID,
                  !serverIDs.contains(serverID) else {
                return
            }
            route = route.returningToOrigin
            appState.select(nil)
        }
        .alert(
            appState.pendingTrust?.replacing == true ? "主机密钥已变化" : "确认 SSH 主机指纹",
            isPresented: Binding(
                get: { appState.pendingTrust != nil },
                set: { if !$0 { appState.pendingTrust = nil } }
            )
        ) {
            Button("取消", role: .cancel) { appState.pendingTrust = nil }
            Button(appState.pendingTrust?.replacing == true ? "替换指纹" : "信任") {
                if let prompt = appState.pendingTrust {
                    Task {
                        await appState.resolveTrust(prompt.probe, replacing: prompt.replacing)
                        TrustedHostCatalog.upsert(probe: prompt.probe, in: modelContext)
                    }
                }
            }
        } message: {
            if let prompt = appState.pendingTrust {
                Text(trustMessage(prompt))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            appState.shutdown()
        }
    }

    private func trustMessage(_ prompt: HostTrustPrompt) -> String {
        if prompt.replacing {
            return "旧指纹：\(prompt.oldFingerprint ?? "未知")\n新指纹：\(prompt.probe.fingerprint)\n替换前请确认这是你预期的主机。"
        }
        return "\(prompt.probe.host):\(prompt.probe.port)\n\(prompt.probe.algorithm) \(prompt.probe.fingerprint)"
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedServer,
           case .server(_, let origin, _) = route {
            ServerDetailView(
                server: selectedServer,
                mode: detailModeBinding,
                backTitle: origin.title,
                onBack: returnToOrigin,
                onEdit: { editingServer = selectedServer },
                onDelete: { serverPendingDeletion = selectedServer }
            )
        } else {
            switch sidebarDestination {
            case .dashboard:
                DashboardOverviewView(
                    servers: servers,
                    scrollAnchor: $dashboardScrollAnchor,
                    onSelect: { server in
                        openServerDetail(
                            server,
                            origin: .dashboard,
                            mode: .monitor
                        )
                    },
                    onOpenTerminal: { server in
                        dashboardScrollAnchor = server.id
                        appState.openTerminal(for: server)
                        route = .server(
                            id: server.id,
                            origin: .dashboard,
                            mode: .terminal
                        )
                    },
                    onAdd: { showingNewServer = true }
                )
            case .machines:
                MachineManagementView(
                    servers: filteredServers,
                    searchText: $searchText,
                    scrollAnchor: $machineScrollAnchor,
                    onSelect: { server in
                        openServerDetail(
                            server,
                            origin: .machines,
                            mode: .monitor
                        )
                    },
                    onAdd: { showingNewServer = true },
                    onEdit: { editingServer = $0 },
                    onDelete: { serverPendingDeletion = $0 }
                )
            case .identities:
                IdentityManagementView()
            case .sshKeys:
                SSHKeyManagementView()
            case .snippets:
                SnippetManagementView()
            case .trustedHosts:
                TrustedHostsView()
            case .terminal:
                TerminalSessionsLandingView(
                    sessions: appState.terminalSessions,
                    onOpen: openTerminalSession,
                    onChooseServer: { navigate(.machines) }
                )
            }
        }
    }

    private func navigate(_ destination: SidebarDestination) {
        route = .section(destination)
        appState.select(nil)
    }

    private func openTerminalSession(_ session: TerminalSession) {
        guard let server = servers.first(where: { $0.id == session.serverID }) else { return }
        appState.selectTerminal(session)
        route = .server(
            id: server.id,
            origin: .terminal,
            mode: .terminal
        )
    }

    private func openServerDetail(
        _ server: ServerRecord,
        origin: SidebarDestination,
        mode: DetailMode
    ) {
        switch origin {
        case .dashboard:
            dashboardScrollAnchor = server.id
        case .machines:
            machineScrollAnchor = server.id
        default:
            break
        }
        appState.select(server)
        appState.detailMode = mode
        route = .server(id: server.id, origin: origin, mode: mode)
    }

    private func returnToOrigin() {
        route = route.returningToOrigin
        appState.select(nil)
    }

    private func synchronizeIdentityConnections() {
        ConnectionConfigResolver.synchronize(
            servers: servers,
            identities: identities,
            keys: sshKeys
        )
        var resolved: [UUID: ServerConnectionConfig] = [:]
        for server in servers {
            resolved[server.id] = ConnectionConfigResolver.resolve(
                server: server,
                identities: identities,
                keys: sshKeys
            )
        }
        appState.applyResolvedConfigs(resolved)
        try? modelContext.save()
    }
}
