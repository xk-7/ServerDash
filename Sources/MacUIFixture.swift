import AppKit
import SwiftData
import SwiftUI

enum MacUIFixturePage: String, CaseIterable, Sendable {
    case dashboard
    case machinesGrid = "machines-grid"
    case machinesList = "machines-list"
    case monitor
    case terminal
    case sftp
    case rdp
    case settings
    case empty
    case dialog
}

enum MacUIFixtureTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct MacUIFixtureAccessibility: Equatable, Sendable {
    var reduceMotion = false
    var reduceTransparency = false
    var increaseContrast = false
}

struct MacUIFixtureConfiguration: Equatable, Sendable {
    var page: MacUIFixturePage = .dashboard
    var theme: MacUIFixtureTheme = .system
    var width: Double = 1440
    var height: Double = 900
    var hostCount = 8
    var paneCount = 1
    var accessibility = MacUIFixtureAccessibility()
}

enum MacUIFixtureIsolationPolicy {
    static let networkDisabledMessage = "隔离验收已禁用网络传输。"

    enum CredentialBackend: Equatable, Sendable {
        case systemKeychain
        case processMemory
    }

    static func blocksNetwork(fixtureEnabled: Bool) -> Bool {
        fixtureEnabled
    }

    static var blocksNetwork: Bool {
        blocksNetwork(fixtureEnabled: MacUIFixture.isEnabled)
    }

    static func credentialBackend(fixtureEnabled: Bool) -> CredentialBackend {
        fixtureEnabled ? .processMemory : .systemKeychain
    }

    static func requireNetworkAllowed(fixtureEnabled: Bool = MacUIFixture.isEnabled) throws {
        guard !blocksNetwork(fixtureEnabled: fixtureEnabled) else {
            throw MacUIFixtureIsolationError.networkDisabled
        }
    }
}

enum MacUIFixtureIsolationError: LocalizedError, Equatable, Sendable {
    case networkDisabled

    var errorDescription: String? {
        MacUIFixtureIsolationPolicy.networkDisabledMessage
    }
}

/// Used only by a separately identified Debug QA app; release launches never enter this path.
enum MacUIFixture {
    static var isEnabled: Bool {
        #if SERVERDASH_MAC_QA
        true
        #else
        false
        #endif
    }

    static var configuration: MacUIFixtureConfiguration {
        configuration(arguments: ProcessInfo.processInfo.arguments)
    }

    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("serverdash-mac-qa-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    static func configuration(arguments: [String]) -> MacUIFixtureConfiguration {
        var result = MacUIFixtureConfiguration()
        if let raw = argument("--fixture-page", in: arguments),
           let page = MacUIFixturePage(rawValue: raw) {
            result.page = page
        }
        if let raw = argument("--fixture-theme", in: arguments),
           let theme = MacUIFixtureTheme(rawValue: raw) {
            result.theme = theme
        }
        if let width = argument("--fixture-width", in: arguments).flatMap(Double.init), width.isFinite {
            result.width = min(3840, max(900, width))
        }
        if let height = argument("--fixture-height", in: arguments).flatMap(Double.init), height.isFinite {
            result.height = min(2160, max(620, height))
        }
        if let count = argument("--fixture-hosts", in: arguments).flatMap(Int.init) {
            result.hostCount = min(1000, max(0, count))
        }
        if let count = argument("--fixture-panes", in: arguments).flatMap(Int.init) {
            result.paneCount = min(16, max(1, count))
        }
        result.accessibility = MacUIFixtureAccessibility(
            reduceMotion: arguments.contains("--fixture-reduce-motion"),
            reduceTransparency: arguments.contains("--fixture-reduce-transparency"),
            increaseContrast: arguments.contains("--fixture-increase-contrast")
        )
        if result.page == .empty { result.hostCount = 0 }
        return result
    }

    static func prepareEnvironment() {
        guard isEnabled else { return }
        // The dedicated target and defaults domain keep fixture settings away from the user's app.
        precondition(Bundle.main.bundleIdentifier?.hasSuffix(".macqa") == true,
                     "Run the ServerDashMacQA target or prepare an isolated QA copy.")
        let configuration = configuration
        let defaults = UserDefaults.standard
        if let domain = Bundle.main.bundleIdentifier {
            defaults.removePersistentDomain(forName: domain)
        }
        defaults.set(0.0, forKey: "refreshInterval")
        defaults.set(true, forKey: "refreshIntervalConfigured")
        PrivacySettings.setLocationLookupEnabled(false, in: defaults)
        defaults.set(false, forKey: "terminal.history.enabled")
        defaults.set(false, forKey: "recordingOutputConsent")
        defaults.set(false, forKey: "hideIPInformation")
        defaults.set(configuration.page == .machinesList ? "list" : "grid", forKey: "machineViewMode")
        defaults.set(configuration.theme.rawValue, forKey: "appAppearance")
        verifyCredentialIsolation()
    }

    static func argument(_ key: String) -> String? {
        argument(key, in: ProcessInfo.processInfo.arguments)
    }

    static func argument(_ key: String, in values: [String]) -> String? {
        guard let i = values.firstIndex(of: key), i + 1 < values.count else { return nil }
        return values[i + 1]
    }

    #if SERVERDASH_MAC_QA
    private static func verifyCredentialIsolation() {
        let credentialID = UUID()
        let secretAccount = "macqa-self-check.\(UUID().uuidString)"
        let aiAccount = "macqa-self-check.\(UUID().uuidString)"
        let rdpID = UUID()
        do {
            defer {
                try? KeychainService.deletePassword(for: credentialID)
                try? KeychainService.deleteSecret(account: secretAccount)
                try? AIProviderKeychain().delete(aiAccount)
                try? RDPCredentials.delete(rdpID)
            }
            try KeychainService.savePassword("qa-login", for: credentialID)
            try KeychainService.saveSecret("qa-secret", account: secretAccount)
            try AIProviderKeychain().write("qa-ai", account: aiAccount)
            try RDPCredentials.save("qa-rdp", id: rdpID)
            let login = try KeychainService.password(for: credentialID)
            let secret = try KeychainService.secret(account: secretAccount)
            let aiKey = try AIProviderKeychain().read(aiAccount)
            let rdpPassword = try RDPCredentials.read(rdpID)
            precondition(login == "qa-login" && secret == "qa-secret" &&
                         aiKey == "qa-ai" && rdpPassword == "qa-rdp")
        } catch {
            preconditionFailure("Mac QA 进程内凭据存储自检失败。")
        }
    }
    #else
    private static func verifyCredentialIsolation() {}
    #endif

    @MainActor static func makeAppState() -> AppState {
        AppState(trustCoordinator: HostTrustCoordinator(
            inspector: { _, _ in throw URLError(.notConnectedToInternet) },
            truster: { _, _ in throw URLError(.notConnectedToInternet) }),
            portForwardSupervisor: PortForwardSupervisor(),
            terminalRegistry: TerminalSessionRegistry(attachProcess: false),
            fileServicesEnabled: false,
            usesIsolatedFixtureBootstrap: true)
    }
    @MainActor static func populate(_ container: ModelContainer, app: AppState) throws {
        let configuration = configuration
        let context = container.mainContext
        let group = MachineGroupRecord(name: "生产环境")
        context.insert(group)
        context.insert(MachineGroupRecord(name: "核心数据库", parentID: group.id))
        context.insert(MachineGroupRecord(name: "开发测试"))
        context.insert(MachineTagRecord(name: "生产", colorName: "red"))
        context.insert(MachineTagRecord(name: "开发", colorName: "blue"))
        let count = configuration.hostCount
        var servers: [ServerRecord] = []
        for i in 0..<count {
            let server = ServerRecord(name: i == 0 ? "上海生产环境核心数据库 · 用于检查长中文名称的主机" : String(format: "%03d 应用服务器", i + 1),
                host: "192.0.2.\(10 + i % 240)", username: "fixture", groupName: i == 0 ? "核心数据库" : i.isMultiple(of: 2) ? "生产环境" : "开发测试",
                tagsText: i.isMultiple(of: 2) ? "生产" : "开发", notes: i == 0 ? "每日备份 · 周日维护窗口" : "",
                enableDashboardMonitor: false, lastLatencyMS: i == 0 ? 19 : 0)
            context.insert(server); servers.append(server)
        }
        var rdpRecord: RDPConnectionRecord?
        if count > 0 {
            let record = try RDPConnectionRecord(name: "Windows 远程桌面", host: "192.0.2.80", username: "fixture", groupName: "生产环境")
            context.insert(record)
            rdpRecord = record
            context.insert(VNCConnectionRecord(name: "屏幕共享", host: "192.0.2.90", groupName: "开发测试"))
            context.insert(SerialConnectionRecord(name: "串口测试台", devicePath: "", groupName: "开发测试"))
        }
        try context.save()
        app.bootstrap(servers: servers, context: context)
        let visualStateIndices: Set<Int> = count <= 32
            ? Set(servers.indices)
            : Set(Array(servers.indices.prefix(16)) + [max(0, count - 2)])
        for (i, server) in servers.enumerated() where visualStateIndices.contains(i) {
            var snapshot = ServerSnapshot.empty
            snapshot.capturedAt = .now; snapshot.distribution = "Ubuntu 24.04 LTS"
            snapshot.cpuUsage = 3.2; snapshot.coreCount = 16
            snapshot.memoryUsedBytes = 1.4 * 1_073_741_824; snapshot.memoryTotalBytes = 16 * 1_073_741_824
            let status: ServerConnectionStatus = [.online, .connecting, .failed, .offline, .unknown][i % 5]
            app.runtime(for: server).publish(ServerRenderState(status: status, snapshot: snapshot,
                error: status == .failed ? "模拟连接超时，可重新尝试" : nil))
        }
        switch configuration.page {
        case .dashboard:
            app.route = .section(.dashboard)
        case .machinesGrid, .machinesList, .empty, .settings:
            app.route = .section(.machines)
        case .monitor:
            if let server = servers.first {
                app.select(server)
                app.route = .server(id: server.id, origin: .machines, mode: .monitor)
            } else {
                app.route = .section(.machines)
            }
        case .terminal:
            guard let server = servers.first else {
                app.route = .section(.terminal)
                return
            }
            let panes = configuration.paneCount
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
            app.route = .section(.terminal)
            // Wait until SwiftTerm has a real pane width so fixture text does not wrap at one column.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                for (index, controller) in controllers.enumerated() {
                    controller.hostView.feedLocalOutput("\u{1B}[2J\u{1B}[HQA 面板 \(index + 1) · 离线夹具\r\nfixture@server:~$ ")
                }
            }
        case .sftp:
            guard let server = servers.first else {
                app.route = .section(.terminal)
                return
            }
            app.openSFTP(for: server, automaticallyConnect: false)
            guard let controller = app.fileControllers.values.first else { return }
            controller.currentPath = "/srv/serverdash"
            controller.pathText = "/srv/serverdash"
            controller.hasLoadedDirectory = true
            controller.statusMessage = "隔离目录 · 未建立网络连接"
            controller.items = [
                RemoteFileItem(path: "/srv/serverdash/config", name: "config", kind: .directory, size: 0,
                               permissions: "drwxr-xr-x", owner: "fixture", group: "fixture", modifiedText: "2026-09-15 09:30"),
                RemoteFileItem(path: "/srv/serverdash/部署说明-生产环境.md", name: "部署说明-生产环境.md", kind: .file, size: 18_432,
                               permissions: "-rw-r--r--", owner: "fixture", group: "fixture", modifiedText: "2026-09-15 09:28"),
                RemoteFileItem(path: "/srv/serverdash/serverdash.log", name: "serverdash.log", kind: .file, size: 8_388_608,
                               permissions: "-rw-r-----", owner: "fixture", group: "adm", modifiedText: "2026-09-15 09:26")
            ]
        case .rdp:
            app.route = rdpRecord.map { .rdp($0.id) } ?? .section(.machines)
        case .dialog:
            app.route = .section(.machines)
        }
    }
    @MainActor static func configureWindow(_ window: NSWindow) {
        guard isEnabled else { return }
        let configuration = configuration
        window.setContentSize(NSSize(width: configuration.width, height: configuration.height))
        window.title = "ServerDash · 隔离验收"
        window.setAccessibilityIdentifier("serverdash.macqa.window")
        window.center()
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

#if SERVERDASH_MAC_QA
/// A deterministic, in-memory RDP source used only by the separately bundled
/// Mac QA application. It never opens a socket or reaches the native FreeRDP
/// bridge; the production desktop renderer receives one opaque black frame.
private final class MacUIFixtureRDPConnectionEngine: RDPConnectionEngine, @unchecked Sendable {
    private let frame: RDPFrame

    init(width: Int = 1280, height: Int = 720) {
        frame = RDPFrame(
            width: width,
            height: height,
            pixels: Data(repeating: 0, count: width * height * 4),
            sequence: 1,
            dirtyRect: CGRect(x: 0, y: 0, width: width, height: height),
            colorDepth: 32,
            connectionID: UUID()
        )
    }

    func start(
        configuration: RDPConnectionConfiguration,
        password: String,
        trust: @escaping @Sendable (RDPCertificateEvidence) -> Bool,
        event: @escaping @Sendable (RDPConnectionEvent) -> Void
    ) {
        event(.displayCapabilities(8_192))
        event(.connected)
    }

    func cancel() {}
    func copyFrame() -> RDPFrame? { frame }
    func key(_ code: UInt16, down: Bool) {}
    func unicode(_ code: UInt16, down: Bool) {}
    func pointer(flags: UInt16, x: UInt16, y: UInt16) {}
    func monitors(_ values: [RDPMonitor]) {}
}

/// Exercises the real RDP desktop chrome and Metal-backed image view without
/// creating a remote connection. The fixture owns and closes the controller so
/// repeated UI-test launches cannot leave polling tasks behind.
@MainActor
struct MacUIFixtureRDPDesktopView: View {
    @StateObject private var controller: RDPSessionController
    @State private var started = false

    init() {
        let configuration = RDPConnectionConfiguration(
            id: UUID(uuidString: "3D58B461-17EF-45A4-A279-C84A2852600A")!,
            name: "Windows 远程桌面 · 离线验收",
            host: "rdp-fixture.invalid",
            port: 3389,
            username: "fixture",
            domain: "SERVERDASH",
            settings: RDPSettings(),
            credentialReference: nil
        )
        _controller = StateObject(wrappedValue: RDPSessionController(
            configuration: configuration,
            password: "fixture-only",
            configurationProvider: { configuration },
            factory: { MacUIFixtureRDPConnectionEngine() }
        ))
    }

    var body: some View {
        RDPDesktopPane(controller: controller)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("macqa.rdp.desktop")
            .onAppear {
                guard !started else { return }
                started = true
                controller.connect()
            }
            .onDisappear { controller.close() }
    }
}
#endif
