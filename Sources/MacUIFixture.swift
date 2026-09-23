import AppKit
import SwiftData
import SwiftTerm
import SwiftUI

enum MacUIFixturePage: String, CaseIterable {
    case dashboard
    case machines
    case terminal
    case recordings
    case identities
    case sshKeys = "ssh-keys"
    case snippets
    case trustedHosts = "trusted-hosts"
    case connections
    case monitor
    case sftp
    case rdp
    case settings
    case ai
    case editor
    case importExport = "import-export"
    case connectionEditor = "connection-editor"
    case batchExecution = "batch-execution"
    case recordingConfiguration = "recording-config"
    case empty
    case error

    init(argument: String?) {
        self = argument.flatMap(Self.init(rawValue:)) ?? .machines
    }

    var section: SidebarDestination? {
        switch self {
        case .dashboard: .dashboard
        case .machines: .machines
        case .terminal: .terminal
        case .recordings: .recordings
        case .identities: .identities
        case .sshKeys: .sshKeys
        case .snippets: .snippets
        case .trustedHosts: .trustedHosts
        case .connections: .connections
        case .monitor, .sftp, .rdp, .settings, .ai, .editor,
             .importExport, .connectionEditor, .batchExecution,
             .recordingConfiguration, .empty, .error: nil
        }
    }
}

/// Used only by the separately compiled QA application target. Runtime arguments
/// cannot enable fixtures in the production application, including Debug builds.
enum MacUIFixture {
    static var isEnabled: Bool {
        #if SERVERDASH_MAC_QA
        Bundle.main.bundleIdentifier == "com.serverdash.app.macqa"
        #else
        false
        #endif
    }
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("serverdash-mac-polish-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    static let sshConfigURL = root
        .appendingPathComponent("SSH", isDirectory: true)
        .appendingPathComponent("config", isDirectory: false)
    static var routeImportSource: SSHConfigImportSource {
        .isolated(sshConfigURL)
    }
    static var sessionImportDiscoveryProvider: SessionImportDiscoveryProvider {
        SessionImportDiscoveryProvider { source in
            switch source {
            case .automatic, .openSSH:
                [sshConfigURL]
            default:
                []
            }
        }
    }

    static func writeSyntheticSSHConfig(to url: URL = sshConfigURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let contents = """
        Host qa-bastion
          HostName 192.0.2.20
          User fixture
          Port 22

        Host qa-target
          HostName 192.0.2.10
          User fixture
          ProxyJump qa-bastion
        """
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    static func prepareEnvironment() {
        guard isEnabled else { return }
        // A dedicated defaults domain prevents fixture settings from touching the user's settings.
        precondition(Bundle.main.bundleIdentifier == "com.serverdash.app.macqa",
                     "Mac UI fixtures are available only in the ServerDashMacQA target.")
        precondition(KeychainService.serviceName == "com.serverdash.app.macqa.credentials")
        precondition(RDPCredentials.service == "com.serverdash.app.macqa.rdp.credentials")
        precondition(AIKeychain.serviceName == "com.serverdash.app.macqa.ai.api-key")
        do {
            try writeSyntheticSSHConfig()
        } catch {
            preconditionFailure("Unable to prepare the isolated SSH Config fixture: \(error)")
        }
        let defaults = UserDefaults.standard
        defaults.removePersistentDomain(forName: "com.serverdash.app.macqa")
        defaults.set(0.0, forKey: "refreshInterval")
        defaults.set(true, forKey: "refreshIntervalConfigured")
        PrivacySettings.setLocationLookupEnabled(false, in: defaults)
        defaults.set(false, forKey: "terminal.history.enabled")
        defaults.set(false, forKey: "recordingOutputConsent")
        defaults.set(false, forKey: "hideIPInformation")
        let machineView = argument("--fixture-machine-view")
        defaults.set(machineView == "list" ? "list" : "grid", forKey: "machineViewMode")
        let settingsPage = argument("--fixture-settings-page").flatMap(SettingsPage.init(rawValue:)) ?? .general
        defaults.set(settingsPage.rawValue, forKey: "mac.settings.selectedPage")
        if let theme = argument("--fixture-theme"), ["light", "dark"].contains(theme) {
            defaults.set(theme, forKey: "appAppearance")
        }
    }
    static func argument(_ key: String) -> String? {
        let values = ProcessInfo.processInfo.arguments
        guard let i = values.firstIndex(of: key), i + 1 < values.count else { return nil }
        return values[i + 1]
    }

    static func hasArgument(_ key: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(key)
    }
    @MainActor static func makeAppState() -> AppState {
        AppState(trustCoordinator: HostTrustCoordinator(
            inspector: { _, _ in throw URLError(.notConnectedToInternet) },
            truster: { _, _ in throw URLError(.notConnectedToInternet) }),
            portForwardSupervisor: PortForwardSupervisor(),
            terminalRegistry: TerminalSessionRegistry(attachProcess: false), fileServicesEnabled: false)
    }
    @MainActor static func populate(_ container: ModelContainer, app: AppState) throws {
        let context = container.mainContext
        let page = MacUIFixturePage(argument: argument("--fixture-page"))
        let group = MachineGroupRecord(name: "生产环境")
        context.insert(group)
        context.insert(MachineGroupRecord(name: "核心数据库", parentID: group.id))
        context.insert(MachineGroupRecord(name: "开发测试"))
        context.insert(MachineGroupRecord(name: "暂无主机的分组"))
        context.insert(MachineTagRecord(name: "生产", colorName: "red"))
        context.insert(MachineTagRecord(name: "开发", colorName: "blue"))
        context.insert(MachineTagRecord(name: "暂无主机的标签", colorName: "gray"))
        let count = argument("--fixture-hosts").flatMap(Int.init).map { min(1000, max(0, $0)) }
            ?? (page == .empty ? 0 : 8)
        var servers: [ServerRecord] = []
        for i in 0..<count {
            let server = ServerRecord(name: i == 0 ? "上海生产环境核心数据库 · 用于检查长中文名称的主机" : String(format: "%03d 应用服务器", i + 1),
                host: "192.0.2.\(10 + i % 240)", username: "fixture", groupName: i == 0 ? "核心数据库" : i.isMultiple(of: 2) ? "生产环境" : "开发测试",
                tagsText: i.isMultiple(of: 2) ? "生产" : "开发", notes: i == 0 ? "每日备份 · 周日维护窗口" : "",
                enableDashboardMonitor: false, lastLatencyMS: i == 0 ? 19 : 0)
            context.insert(server); servers.append(server)
        }
        var rdpID: UUID?
        if count > 0 {
            let rdp = try RDPConnectionRecord(name: "Windows 远程桌面", host: "192.0.2.80", username: "fixture", groupName: "生产环境")
            context.insert(rdp)
            rdpID = rdp.id
            context.insert(VNCConnectionRecord(name: "屏幕共享", host: "192.0.2.90", groupName: "开发测试"))
            context.insert(SerialConnectionRecord(name: "串口测试台", devicePath: "", groupName: "开发测试"))
        }
        try context.save()
        app.bootstrap(servers: servers, context: context)
        for (i, server) in servers.enumerated() {
            var snapshot = ServerSnapshot.empty
            snapshot.capturedAt = .now; snapshot.distribution = "Ubuntu 24.04 LTS"
            snapshot.cpuUsage = 3.2; snapshot.coreCount = 16
            snapshot.memoryUsedBytes = 1.4 * 1_073_741_824; snapshot.memoryTotalBytes = 16 * 1_073_741_824
            let status: ServerConnectionStatus = [.online, .connecting, .failed, .offline, .unknown][i % 5]
            app.runtime(for: server).publish(ServerRenderState(status: status, snapshot: snapshot,
                error: status == .failed ? "模拟连接超时，可重新尝试" : nil))
        }
        if page == .terminal || page == .batchExecution, let server = servers.first {
            let panes = page == .batchExecution
                ? 3
                : argument("--fixture-panes").flatMap(Int.init).map { min(16, max(1, $0)) } ?? 1
            var first: UUID?
            var controllers: [TerminalSessionController] = []
            for _ in 0..<panes {
                let controller = app.terminalRegistry.open(for: server, forceNew: true, startImmediately: false)
                controller.status = .connected
                controllers.append(controller)
                if let first { _ = app.terminalRegistry.workspace.split(first, inserting: controller.id, axis: .right) }
                else { first = controller.id }
            }
            app.terminalRegistry.workspace.arrangeGrid()
            if page == .terminal { app.route = .section(.terminal) }
            // Wait until SwiftTerm has a real pane width so fixture text does not wrap at one column.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                for (index, controller) in controllers.enumerated() {
                    controller.hostView.feedLocalOutput("\u{1B}[2J\u{1B}[HQA 面板 \(index + 1) · 离线夹具\r\nfixture@server:~$ ")
                }
            }
        } else if page == .monitor, let server = servers.first {
            app.select(server)
            app.detailMode = .monitor
            app.route = .server(id: server.id, origin: .machines, mode: .monitor)
        } else if page == .rdp, let rdpID {
            app.route = .rdp(rdpID)
        } else {
            app.route = .section(page.section ?? .machines)
        }
    }

    @MainActor static func makeEditorStore() -> RemoteEditorStore {
        let store = RemoteEditorStore(
            persistURL: root.appendingPathComponent("Editor/documents.json"),
            restore: false
        )
        let text = """
        # ServerDash 隔离编辑器夹具

        server:
          host: 192.0.2.10
          monitoring: true
        """
        let data = Data(text.utf8)
        let draft = RemoteEditorDraft(
            serverID: UUID(),
            serverName: "上海生产环境核心数据库",
            path: "/etc/serverdash/example.yml",
            text: text,
            encoding: .utf8,
            hasBOM: false,
            original: data,
            revision: RemoteFileRevision(
                size: Int64(data.count),
                modifiedNS: 1,
                inode: 1,
                mode: 0o640,
                uid: 0,
                gid: 0,
                sha256: DesktopFileOperations.digest(data)
            )
        )
        store.documents = [draft]
        store.selectedID = draft.id
        return store
    }

    static func makeSyntheticRecording() throws -> RecordingDocument {
        let directory = root.appendingPathComponent("Recording", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("offline-fixture.sdrec")
        let delegate = MacUIFixtureTerminalDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 48, rows: 8))
        terminal.feed(text: "ServerDash 离线录制验收\r\nfixture@server:~$ echo safe\r\n")
        let frame = RecordingFrame(
            screen: terminal.displaySnapshot(),
            appearance: RecordingAppearance(fontName: "Menlo", fontSize: 12, cellWidth: 7, cellHeight: 15),
            changedRows: nil
        )
        try frame.validate()
        let header = RecordingEvent(kind: .header, time: 0, header: RecordingHeader(name: "离线录制夹具"))
        let headerBlock = try RecordingCodec.encode(header)
        let screenOffset = UInt64(RecordingCodec.magic.count + headerBlock.count)
        let index = [RecordingIndexEntry(time: 0, offset: screenOffset)]
        var data = RecordingCodec.magic
        data.append(headerBlock)
        data.append(try RecordingCodec.encode(RecordingEvent(kind: .screen, time: 0, frame: frame)))
        data.append(try RecordingCodec.encode(RecordingEvent(
            kind: .output,
            time: 0.5,
            output: Data("offline fixture output\r\n".utf8)
        )))
        data.append(try RecordingCodec.encode(RecordingEvent(
            kind: .end,
            time: 2,
            index: index,
            reason: "user"
        )))
        try data.write(to: url, options: .atomic)
        return try RecordingDocument.open(url)
    }
    @MainActor static func configureWindow(_ window: NSWindow) {
        guard isEnabled else { return }
        let width = argument("--fixture-width").flatMap(Double.init) ?? 1440
        let height = argument("--fixture-height").flatMap(Double.init) ?? 900
        window.setContentSize(NSSize(width: max(900, width), height: max(620, height)))
        window.title = "ServerDash · 隔离验收"
        window.center()
    }
}

@MainActor
struct MacUIFixtureRootView: View {
    @EnvironmentObject private var appState: AppState
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]
    @Query(sort: \SSHKeyRecord.name) private var keys: [SSHKeyRecord]
    @StateObject private var editorStore: RemoteEditorStore

    private let page: MacUIFixturePage

    init() {
        let selectedPage = MacUIFixturePage(argument: MacUIFixture.argument("--fixture-page"))
        page = selectedPage
        _editorStore = StateObject(wrappedValue: MacUIFixture.makeEditorStore())
    }

    var body: some View {
        fixtureContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(
                \.macAccessibilityOverrides,
                MacAccessibilityOverrides(
                    reduceMotion: MacUIFixture.hasArgument("--fixture-reduce-motion"),
                    reduceTransparency: MacUIFixture.hasArgument("--fixture-reduce-transparency"),
                    increaseContrast: MacUIFixture.hasArgument("--fixture-increase-contrast")
                )
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("macqa.page.\(page.rawValue)")
    }

    @ViewBuilder
    private var fixtureContent: some View {
        switch page {
        case .settings:
            SettingsView()
        case .sftp:
            if let server = servers.first {
                NavigationSplitView {
                    List {
                        Label("远程文件", systemImage: "folder")
                    }
                    .navigationTitle("工作区")
                    .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 220)
                } detail: {
                    MacUIFixtureSFTPHost(server: server, appState: appState)
                }
            } else {
                MacUIFixtureStateView(kind: .empty)
            }
        case .ai:
            AIGeneralWindow()
        case .editor:
            MacUIFixtureSheetHost {
                RemoteEditorView(store: editorStore)
            }
        case .importExport:
            MacUIFixtureSheetHost {
                if MacUIFixture.argument("--fixture-transfer-mode") == "export" {
                    SessionExportWizard(servers: servers)
                } else {
                    SessionImportWizard(
                        existingServers: servers,
                        discoveryProvider: MacUIFixture.sessionImportDiscoveryProvider
                    )
                }
            }
        case .connectionEditor:
            MacUIFixtureSheetHost {
                connectionEditor
            }
        case .batchExecution:
            MacUIFixtureSheetHost {
                TerminalBatchExecutionSheet(registry: appState.terminalRegistry)
            }
        case .recordingConfiguration:
            MacUIFixtureRecordingConfigurationHost()
        case .empty:
            MacUIFixtureStateView(kind: .empty)
        case .error:
            MacUIFixtureErrorHost()
        default:
            ContentView()
        }
    }

    @ViewBuilder
    private var connectionEditor: some View {
        switch MacUIFixture.argument("--fixture-connection-editor") ?? "ssh" {
        case "rdp":
            RDPEditorView(record: nil)
        case "vnc":
            VNCEditorView()
        case "serial":
            SerialEditorView()
        case "identity":
            IdentityEditorView(identity: nil, keys: keys)
        case "key":
            SSHKeyEditorView(key: nil)
        case "snippet":
            SnippetEditorView(snippet: nil)
        case "route":
            if let server = servers.first {
                SSHConnectionRouteEditor(
                    server: server,
                    importSource: MacUIFixture.routeImportSource
                )
            } else {
                MacUIFixtureStateView(kind: .empty)
            }
        case "tunnel":
            if let server = servers.first {
                TerminalTunnelManagerView(server: server)
            } else {
                MacUIFixtureStateView(kind: .empty)
            }
        default:
            ServerEditorView(server: nil)
        }
    }
}

/// The SFTP QA route mounts the production browser with a synthetic listing.
/// Its controller never connects, so layout checks cannot contact a saved host.
@MainActor
private struct MacUIFixtureSFTPHost: View {
    @StateObject private var controller: MacSFTPController

    init(server: ServerRecord, appState: AppState) {
        _controller = StateObject(wrappedValue: MacSFTPController(
            server: server,
            appState: appState,
            automaticallyConnect: false
        ))
    }

    var body: some View {
        SFTPBrowserView(controller: controller, chromeMode: .full)
            .onAppear {
                guard !controller.hasLoadedDirectory else { return }
                let path = "/srv/生产环境/包含空格与中文的长期部署路径/应用程序"
                let items = (0..<24).map { index in
                    let name = index == 0 ? "上海生产环境核心数据库配置文件.yaml" : String(format: "应用配置-%02d.txt", index)
                    return RemoteFileItem(
                        path: path + "/" + name,
                        name: name,
                        kind: .file,
                        size: Int64(1_024 + index * 2_048),
                        permissions: "rw-r--r--",
                        owner: "fixture",
                        group: "fixture",
                        modifiedText: "2026-09-21"
                    )
                } + [RemoteFileItem(
                    path: path + "/.hidden-config",
                    name: ".hidden-config",
                    kind: .file,
                    size: 128,
                    permissions: "rw-------",
                    owner: "fixture",
                    group: "fixture",
                    modifiedText: "2026-09-21"
                )]
                controller.applyDirectoryListing(SFTPDirectoryListing(path: path, items: items))
                controller.selection = [items[0].id]
                controller.statusMessage = "离线夹具 · \(items.count) 项"
            }
    }
}

private final class MacUIFixtureTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

private struct MacUIFixtureRecordingConfigurationHost: View {
    @State private var document: RecordingDocument?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let document {
                MacUIFixtureSheetHost {
                    GIFExportView(document: document)
                }
            } else if let errorMessage {
                ContentUnavailableView(
                    "无法创建录制夹具",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("正在准备离线录制…")
            }
        }
        .task {
            guard document == nil, errorMessage == nil else { return }
            do { document = try MacUIFixture.makeSyntheticRecording() }
            catch { errorMessage = "隔离录制数据生成失败。" }
        }
    }
}

private struct MacUIFixtureSheetHost<SheetContent: View>: View {
    @State private var isPresented = false
    @ViewBuilder let sheetContent: SheetContent

    init(@ViewBuilder sheetContent: () -> SheetContent) {
        self.sheetContent = sheetContent()
    }

    var body: some View {
        ContentUnavailableView {
            Label("模态验收场景", systemImage: "macwindow.on.rectangle")
        } description: {
            Text("内容通过真实 macOS Sheet 呈现。")
        }
        .accessibilityIdentifier("macqa.modal.host")
        .task {
            await Task.yield()
            isPresented = true
        }
        .sheet(isPresented: $isPresented) {
            sheetContent
        }
    }
}

private struct MacUIFixtureErrorHost: View {
    @State private var showsError = false

    var body: some View {
        ContentUnavailableView {
            Label("工作台", systemImage: "server.rack")
        } description: {
            Text("等待错误反馈验收。")
        }
        .accessibilityIdentifier("macqa.error.host")
        .task {
            await Task.yield()
            showsError = true
        }
        .alert("无法载入工作台", isPresented: $showsError) {
            Button("取消", role: .cancel) {}
                .accessibilityIdentifier("macqa.error.cancel")
            Button("重试") {}
                .accessibilityIdentifier("macqa.error.retry")
        } message: {
            Text("隔离夹具模拟了数据读取失败；用户数据和网络均未访问。")
        }
    }
}

private struct MacUIFixtureStateView: View {
    enum Kind { case empty, error }
    let kind: Kind

    var body: some View {
        ContentUnavailableView {
            Label(
                kind == .empty ? "还没有任何主机" : "无法载入工作台",
                systemImage: kind == .empty ? "server.rack" : "exclamationmark.triangle"
            )
        } description: {
            Text(kind == .empty
                 ? "导入配置或添加主机，开始使用 ServerDash。"
                 : "隔离夹具模拟了数据读取失败；用户数据和网络均未访问。")
        } actions: {
            Button(kind == .empty ? "添加主机" : "重试") {}
                .accessibilityIdentifier(kind == .empty ? "macqa.empty.action" : "macqa.error.retry")
        }
    }
}

struct MacFixtureWindowSetup: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class View: NSView {
        private var configured = false
        override func viewDidMoveToWindow() {
            guard !configured, let window else { return }
            configured = true
            DispatchQueue.main.async { MacUIFixture.configureWindow(window) }
        }
    }
}
