import SwiftData
import SwiftUI

@main
struct ServerDashMobileApp: App {
    @StateObject private var persistence = PersistenceSession()
    @StateObject private var runtime = MobileRuntime()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearanceRawValue = AppAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = persistence.container {
                    MobileRootView()
                        .environmentObject(runtime)
                        .modelContainer(container)
                } else if let error = persistence.openError {
                    DatabaseRecoveryView(
                        error: error,
                        backupURL: persistence.lastBackupURL,
                        onRetry: persistence.open,
                        onRebuild: persistence.rebuild
                    )
                } else {
                    ProgressView("正在打开本地数据库…")
                }
            }
            .preferredColorScheme(
                (AppAppearance(rawValue: appearanceRawValue) ?? .system).colorScheme
            )
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    runtime.resumeFromBackground()
                case .background:
                    runtime.suspendForBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
        }
    }
}

enum MobileDestination: String, CaseIterable, Identifiable {
    case dashboard
    case machines
    case sessions
    case identities
    case keys
    case snippets
    case trustedHosts
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "仪表盘"
        case .machines: "机器"
        case .sessions: "终端会话"
        case .identities: "身份"
        case .keys: "SSH 密钥"
        case .snippets: "命令片段"
        case .trustedHosts: "可信主机"
        case .settings: "设置"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.50percent"
        case .machines: "server.rack"
        case .sessions: "terminal"
        case .identities: "person.crop.circle.badge.checkmark"
        case .keys: "key"
        case .snippets: "curlybraces"
        case .trustedHosts: "checkmark.shield"
        case .settings: "gearshape"
        }
    }
}

struct MobileRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var runtime: MobileRuntime
    @State private var selection: MobileDestination? = .dashboard
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]
    @Query private var identities: [IdentityRecord]
    @Query private var keys: [SSHKeyRecord]
    @Query private var routes: [ConnectionRouteRecord]
    @AppStorage("mobileRefreshInterval") private var refreshInterval = 15

    private struct Schedule: Equatable {
        let serverIDs: [UUID]
        let monitoredIDs: [UUID]
        let interval: Int
        let backgrounded: Bool
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    List(MobileDestination.allCases, selection: $selection) { destination in
                        Label(destination.title, systemImage: destination.symbol)
                            .tag(destination)
                            .frame(minHeight: 44)
                    }
                    .navigationTitle("ServerDash")
                } detail: {
                    NavigationStack {
                        destinationView(selection ?? .dashboard)
                    }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                TabView {
                    NavigationStack { MobileDashboardView() }
                        .tabItem { Label("仪表盘", systemImage: MobileDestination.dashboard.symbol) }
                    NavigationStack { MobileMachinesView() }
                        .tabItem { Label("机器", systemImage: MobileDestination.machines.symbol) }
                    NavigationStack { MobileSessionsView() }
                        .tabItem { Label("会话", systemImage: MobileDestination.sessions.symbol) }
                    NavigationStack { MobileMoreView() }
                        .tabItem { Label("更多", systemImage: "ellipsis.circle") }
                }
            }
        }
        .background(Color.appGround)
        .overlay { MobileTrustPresenter(broker: runtime.trustBroker) }
        .task(id: Schedule(serverIDs: servers.map(\.id),
                           monitoredIDs: servers.filter(\.enableDashboardMonitor).map(\.id),
                           interval: refreshInterval, backgrounded: runtime.isBackgrounded)) {
            runtime.reconcileServers(servers)
            guard !runtime.isBackgrounded, refreshInterval > 0 else { return }
            while !Task.isCancelled {
                await runtime.refreshAll(servers: servers, identities: identities, keys: keys,
                                         routes: routes, automatic: true)
                do { try await Task.sleep(for: .seconds(max(5, refreshInterval))) }
                catch { return }
            }
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: MobileDestination) -> some View {
        switch destination {
        case .dashboard: MobileDashboardView()
        case .machines: MobileMachinesView()
        case .sessions: MobileSessionsView()
        case .identities: MobileIdentitiesView()
        case .keys: MobileKeysView()
        case .snippets: MobileSnippetsView()
        case .trustedHosts: MobileTrustedHostsView()
        case .settings: MobileSettingsView()
        }
    }
}

private struct MobileMoreView: View {
    var body: some View {
        List {
            Section("资源") {
                NavigationLink { MobileIdentitiesView() } label: {
                    Label("身份", systemImage: MobileDestination.identities.symbol)
                }
                NavigationLink { MobileKeysView() } label: {
                    Label("SSH 密钥", systemImage: MobileDestination.keys.symbol)
                }
                NavigationLink { MobileSnippetsView() } label: {
                    Label("命令片段", systemImage: MobileDestination.snippets.symbol)
                }
            }
            Section("连接与安全") {
                NavigationLink { MobileTrustedHostsView() } label: {
                    Label("可信主机", systemImage: MobileDestination.trustedHosts.symbol)
                }
                LabeledContent("连接与隧道", value: "仅 macOS")
                    .foregroundStyle(.secondary)
            }
            Section {
                NavigationLink { MobileSettingsView() } label: {
                    Label("设置", systemImage: MobileDestination.settings.symbol)
                }
            }
        }
        .navigationTitle("更多")
    }
}

private struct MobileTrustPresenter: View {
    @ObservedObject var broker: MobileHostTrustBroker

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .sheet(item: Binding(
                get: { broker.pending },
                set: { if $0 == nil, broker.pending != nil { broker.respond(.reject) } }
            )) { request in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Image(systemName: request.changed ? "exclamationmark.shield" : "checkmark.shield")
                                .font(.system(size: 44))
                                .foregroundStyle(request.changed ? Color.appError : Color.appAccent)
                                .accessibilityHidden(true)
                            Text(request.changed ? "主机密钥已变化" : "确认主机身份")
                                .font(.title2.bold())
                            Text(request.changed
                                 ? "服务器返回的密钥与本机记录不一致。请通过可信渠道核对后再继续。"
                                 : "这是本设备首次连接该地址。请核对服务器指纹。")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 12) {
                                LabeledContent("主机", value: request.presentation.host)
                                LabeledContent("端口", value: String(request.presentation.port))
                                LabeledContent("算法", value: request.presentation.algorithm)
                                if let old = request.oldFingerprint {
                                    fingerprintRow("旧指纹", old)
                                }
                                fingerprintRow("新指纹", request.presentation.fingerprint)
                            }
                            .padding()
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                        }
                        .padding()
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("拒绝", role: .cancel) { broker.respond(.reject) }
                        }
                        ToolbarItemGroup(placement: .confirmationAction) {
                            Button("仅本次") { broker.respond(.trustOnce) }
                            Button(request.changed ? "替换并信任" : "信任并保存") {
                                broker.respond(.trustAndStore)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .interactiveDismissDisabled()
                .presentationDetents([.medium, .large])
            }
    }

    private func fingerprintRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}
