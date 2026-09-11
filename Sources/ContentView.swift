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
    case connections
    case terminal
    case recordings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "仪表盘"
        case .machines: "机器"
        case .identities: "身份"
        case .sshKeys: "SSH 密钥"
        case .snippets: "代码片段"
        case .trustedHosts: "可信主机"
        case .connections: "连接与隧道"
        case .terminal: "会话"
        case .recordings: "录制"
        }
    }
}

private struct HostTrustAlertModifier: ViewModifier {
    let pendingTrust: HostTrustRequest?
    let isSuppressed: Bool
    let message: String
    let onCancel: (UUID) -> Void
    let onAccept: (HostTrustRequest) -> Void

    func body(content: Content) -> some View {
        content.alert(
            pendingTrust?.replacing == true ? "主机密钥已变化" : "确认 SSH 主机指纹",
            isPresented: Binding(
                get: { pendingTrust != nil && !isSuppressed },
                set: { _ in }
            )
        ) {
            Button("取消", role: .cancel) {
                if let requestID = pendingTrust?.id { onCancel(requestID) }
            }
            Button(pendingTrust?.replacing == true ? "替换指纹" : "信任") {
                if let pendingTrust { onAccept(pendingTrust) }
            }
        } message: {
            Text(message)
        }
    }
}

enum MainContentRoute: Equatable {
    case section(SidebarDestination)
    case rdp(UUID)
    case server(id: UUID, origin: SidebarDestination, mode: DetailMode)

    var sidebarDestination: SidebarDestination {
        switch self {
        case .rdp: .machines
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
    @Query(sort: \RDPConnectionRecord.name) private var rdpMachines: [RDPConnectionRecord]
    @Query(sort: \IdentityRecord.name) private var identities: [IdentityRecord]
    @Query(sort: \SSHKeyRecord.name) private var sshKeys: [SSHKeyRecord]
    @Query(sort: \ConnectionRouteRecord.updatedAt) private var connectionRoutes: [ConnectionRouteRecord]
    @Query(sort: \PortForwardRuleRecord.updatedAt) private var portForwardRules: [PortForwardRuleRecord]

    @State private var searchText = ""
    @State private var showingNewServer = false
    @State private var showingNewRDP = false
    @State private var showingNewVNC = false
    @State private var showingNewSerial = false
    @State private var showingMachineType = false
    @State private var showingSessionImport = false
    @State private var showingSessionExport = false
    @State private var editingServer: ServerRecord?
    @State private var serverPendingDeletion: ServerRecord?
    private var route: MainContentRoute {
        get { appState.route }
        nonmutating set { appState.route = newValue }
    }
    @State private var dashboardScrollAnchor: UUID?
    @State private var machineScrollAnchor: UUID?

    private var sidebarDestination: SidebarDestination {
        route.sidebarDestination
    }

    private var selectedServer: ServerRecord? {
        guard let serverID = route.serverID else { return nil }
        return servers.first { $0.id == serverID }
    }

    private var detailModeBinding: Binding<DetailMode> {
        Binding(
            get: { route.detailMode ?? .monitor },
            set: { mode in
                guard case .server(let id, let origin, _) = route else { return }
                if mode == .terminal, let server = servers.first(where: { $0.id == id }) {
                    appState.openTerminal(for: server)
                } else if mode == .sftp, let server = servers.first(where: { $0.id == id }) {
                    appState.openSFTP(for: server)
                } else {
                    route = .server(id: id, origin: origin, mode: .monitor)
                }
            }
        )
    }

    private var serverDeletionSummary: String {
        guard let server = serverPendingDeletion else {
            return "服务器配置和专用凭据会被移除。"
        }
        let routeCount = connectionRoutes.count { $0.serverID == server.id }
        let ruleCount = portForwardRules.count { $0.serverID == server.id }
        return "服务器配置、专用凭据、\(DisplayFormat.integer(routeCount)) 条连接路线和 \(DisplayFormat.integer(ruleCount)) 条隧道规则都会被移除；活动隧道会先停止，共享身份会保留。此操作无法撤销。"
    }

    var body: some View {
        lifecycleView
    }

    private var navigationView: some View {
        NavigationSplitView {
            AppSidebar(
                selection: sidebarDestination,
                terminalCount: appState.terminalRegistry.workspace.tabs.count,
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
        .navigationTitle("ServerDash")
        .focusedSceneValue(\.workbenchHostActions, WorkbenchHostActions(
            canRefresh: !servers.isEmpty,
            add: { showingMachineType = true },
            refresh: { Task { await appState.refreshAll(servers) } },
            retryFailed: { Task { await appState.refreshAll(servers, failedOnly: true) } }
        ))
    }

    private var presentationView: some View {
        navigationView
        .alert("RDP 远程桌面", isPresented: Binding(get: { appState.rdpError != nil }, set: { if !$0 { appState.rdpError = nil } })) {
            Button("好") { appState.rdpError = nil }
        } message: { Text(appState.rdpError ?? "") }
        .confirmationDialog("添加机器", isPresented: $showingMachineType) {
            Button("SSH 服务器") { showingNewServer = true }
            Button("RDP 远程桌面") { showingNewRDP = true }
            Button("VNC 屏幕共享") { showingNewVNC = true }
            Button("串口设备") { showingNewSerial = true }
        }
        .sheet(isPresented: $showingNewVNC) { VNCEditorView() }
        .sheet(isPresented: $showingNewSerial) { SerialEditorView() }
        .sheet(isPresented: $showingNewRDP) {
            RDPEditorView(record: nil) { record, connect, password in
                route = .rdp(record.id)
                if connect { appState.openRDP(record, password: password) }
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
        .sheet(isPresented: $showingSessionImport) {
            SessionImportWizard(existingServers: servers)
        }
        .sheet(isPresented: $showingSessionExport) {
            SessionExportWizard(servers: servers)
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
                Task { await deleteServerAndReferences(server) }
            }
        } message: {
            Text(serverDeletionSummary)
        }
    }

    private var lifecycleView: some View {
        presentationView
        .task {
            synchronizeIdentityConnections()
            appState.bootstrap(servers: servers, context: modelContext)
            LaunchPerformanceTracker.shared.markInteractive()
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
        .onChange(of: connectionRoutes.map(\.revision)) {
            synchronizeIdentityConnections()
        }
        .onChange(of: servers.map(\.id)) { _, serverIDs in
            handleServerListChange(serverIDs)
        }
        .modifier(
            HostTrustAlertModifier(
                pendingTrust: appState.pendingTrust,
                isSuppressed: showingNewServer || editingServer != nil,
                message: appState.pendingTrust.map(trustMessage) ?? "",
                onCancel: { requestID in appState.cancelTrust(requestID) },
                onAccept: { prompt in
                    Task {
                        if let probe = await appState.resolveTrust(prompt.id) {
                            TrustedHostCatalog.upsert(probe: probe, in: modelContext)
                        }
                    }
                }
            )
        )
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            appState.shutdown()
        }
    }

    private func handleServerListChange(_ serverIDs: [UUID]) {
        guard let serverID = route.serverID,
              !serverIDs.contains(serverID) else {
            return
        }
        route = route.returningToOrigin
        appState.select(nil)
    }

    private func trustMessage(_ prompt: HostTrustRequest) -> String {
        if prompt.replacing {
            return "来源：\(prompt.source.title)\n旧指纹：\(prompt.oldFingerprint ?? "未知")\n新指纹：\(prompt.probe.fingerprint)\n替换前请确认这是你预期的主机。"
        }
        return "来源：\(prompt.source.title)\n\(prompt.probe.host):\(prompt.probe.port)\n\(prompt.probe.algorithm) \(prompt.probe.fingerprint)"
    }

    @ViewBuilder
    private var detailContent: some View {
        if case .rdp(let id) = route, let machine = rdpMachines.first(where: { $0.id == id }) {
            RDPMachineDetail(record: machine, onBack: { route = .section(.machines) })
        } else if let selectedServer,
           case .server(_, let origin, _) = route {
            ServerDetailView(
                server: selectedServer,
                runtime: appState.runtime(for: selectedServer),
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

                    },
                    onAdd: { showingNewServer = true }
                )
            case .machines:
                MachineManagementView(
                    servers: servers,
                    rdpMachines: rdpMachines,
                    onSelectRDP: { route = .rdp($0.id) },
                    searchText: $searchText,
                    scrollAnchor: $machineScrollAnchor,
                    onSelect: { server in
                        openServerDetail(
                            server,
                            origin: .machines,
                            mode: .monitor
                        )
                    },
                    onAdd: { showingMachineType = true },
                    onImport: { showingSessionImport = true },
                    onExport: { showingSessionExport = true },
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
            case .connections:
                ProfessionalConnectionsView()
            case .terminal:
                TerminalWorkspaceView()
            case .recordings:
                RecordingLibraryView()
            }
        }
    }

    private func navigate(_ destination: SidebarDestination) {
        route = .section(destination)
        appState.select(nil)
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
                keys: sshKeys,
                routes: connectionRoutes
            )
        }
        appState.applyResolvedConfigs(resolved)
        try? modelContext.save()
    }

    @MainActor
    private func deleteServerAndReferences(_ server: ServerRecord) async {
        do {
            let proxySecretAccounts = connectionRoutes
                .filter { $0.serverID == server.id }
                .compactMap { $0.route?.proxy?.secretAccount }
            for rule in portForwardRules where rule.serverID == server.id {
                try? await appState.stopPortForward(ruleID: rule.id, serverID: server.id)
                modelContext.delete(rule)
            }
            for connectionRoute in connectionRoutes where connectionRoute.serverID == server.id {
                modelContext.delete(connectionRoute)
            }
            for settings in try modelContext.fetch(FetchDescriptor<SSHAdvancedSettingsRecord>()) where settings.serverID == server.id {
                modelContext.delete(settings)
            }
            try KeychainService.deletePassword(for: server.id)
            try? KeychainService.deleteSecret(
                account: KeychainService.passphraseAccount(for: server.id)
            )
            appState.removeRuntimeData(for: server.id)
            modelContext.delete(server)
            try modelContext.save()
            for account in proxySecretAccounts {
                try? KeychainService.deleteSecret(account: account)
            }
            if route.serverID == server.id {
                route = route.returningToOrigin
            }
            EventLogStore.shared.append(
                serverID: server.id,
                module: .data,
                message: "已删除服务器配置及连接引用"
            )
        } catch {
            EventLogStore.shared.append(
                serverID: server.id,
                module: .data,
                level: "error",
                message: "删除服务器失败"
            )
        }
        serverPendingDeletion = nil
    }
}
