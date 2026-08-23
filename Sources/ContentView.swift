import SwiftData
import SwiftUI

enum SidebarDestination: String, Identifiable, Hashable {
    case dashboard
    case machines
    case identities
    case sshKeys
    case snippets
    case terminal

    var id: String { rawValue }
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
    @State private var sidebarDestination: SidebarDestination = .dashboard
    @State private var showingServerDetail = false

    private var filteredServers: [ServerRecord] {
        guard !searchText.isEmpty else { return servers }
        return servers.filter { server in
            [server.name, server.host, server.groupName, server.tagsText]
                .contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var selectedServer: ServerRecord? {
        servers.first { $0.id == appState.selectedServerID }
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
            if sidebarDestination == .machines && !showingServerDetail {
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
                appState.select(server)
                showingServerDetail = true
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
                try? KeychainService.deletePassword(for: server.id)
                appState.removeRuntimeData(for: server.id)
                modelContext.delete(server)
                try? modelContext.save()
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
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedServer,
           showingServerDetail || appState.detailMode != .monitor {
            ServerDetailView(
                server: selectedServer,
                onEdit: { editingServer = selectedServer },
                onDelete: { serverPendingDeletion = selectedServer }
            )
        } else {
            switch sidebarDestination {
            case .dashboard:
                DashboardOverviewView(
                    servers: servers,
                    onSelect: { server in
                        appState.select(server)
                        showingServerDetail = true
                    },
                    onAdd: { showingNewServer = true }
                )
            case .machines:
                MachineManagementView(
                    servers: filteredServers,
                    searchText: $searchText,
                    onSelect: { server in
                        appState.select(server)
                        showingServerDetail = true
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
        sidebarDestination = destination
        showingServerDetail = false
        appState.select(nil)
    }

    private func openTerminalSession(_ session: TerminalSession) {
        guard let server = servers.first(where: { $0.id == session.serverID }) else { return }
        appState.select(server)
        appState.selectedTerminalID = session.id
        appState.detailMode = .terminal
        showingServerDetail = true
    }

    private func synchronizeIdentityConnections() {
        ConnectionConfigResolver.synchronize(
            servers: servers,
            identities: identities,
            keys: sshKeys
        )
        try? modelContext.save()
    }
}
