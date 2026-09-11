import AppKit
import SwiftData
import SwiftUI

/// Used only by a separately identified Debug QA app; release launches never enter this path.
enum MacUIFixture {
    static var isEnabled: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--mac-ui-fixture")
        #else
        false
        #endif
    }
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("serverdash-mac-polish-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    static func prepareEnvironment() {
        guard isEnabled else { return }
        // A different defaults domain prevents fixture settings from touching the user's settings.
        precondition(Bundle.main.bundleIdentifier?.hasSuffix(".macqa") == true,
                     "Use Scripts/prepare-mac-ui-fixture.sh to create the isolated QA app.")
        let defaults = UserDefaults.standard
        defaults.set(0.0, forKey: "refreshInterval")
        defaults.set(true, forKey: "refreshIntervalConfigured")
        defaults.set(true, forKey: "disableLocationLookup")
        defaults.set(false, forKey: "terminal.history.enabled")
        defaults.set(false, forKey: "recordingOutputConsent")
        defaults.set(false, forKey: "hideIPInformation")
        defaults.set("grid", forKey: "machineViewMode")
        if let theme = argument("--fixture-theme"), ["light", "dark"].contains(theme) {
            defaults.set(theme, forKey: "appAppearance")
        }
    }
    static func argument(_ key: String) -> String? {
        let values = ProcessInfo.processInfo.arguments
        guard let i = values.firstIndex(of: key), i + 1 < values.count else { return nil }
        return values[i + 1]
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
        let group = MachineGroupRecord(name: "生产环境")
        context.insert(group)
        context.insert(MachineGroupRecord(name: "核心数据库", parentID: group.id))
        context.insert(MachineGroupRecord(name: "开发测试"))
        context.insert(MachineTagRecord(name: "生产", colorName: "red"))
        context.insert(MachineTagRecord(name: "开发", colorName: "blue"))
        let count = argument("--fixture-hosts").flatMap(Int.init).map { min(1000, max(0, $0)) } ?? 8
        var servers: [ServerRecord] = []
        for i in 0..<count {
            let server = ServerRecord(name: i == 0 ? "上海生产环境核心数据库 · 用于检查长中文名称的主机" : String(format: "%03d 应用服务器", i + 1),
                host: "192.0.2.\(10 + i % 240)", username: "fixture", groupName: i == 0 ? "核心数据库" : i.isMultiple(of: 2) ? "生产环境" : "开发测试",
                tagsText: i.isMultiple(of: 2) ? "生产" : "开发", notes: i == 0 ? "每日备份 · 周日维护窗口" : "",
                enableDashboardMonitor: false, lastLatencyMS: i == 0 ? 19 : 0)
            context.insert(server); servers.append(server)
        }
        if count > 0 {
            context.insert(try RDPConnectionRecord(name: "Windows 远程桌面", host: "192.0.2.80", username: "fixture", groupName: "生产环境"))
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
        if argument("--fixture-page") == "terminal", let server = servers.first {
            let panes = argument("--fixture-panes").flatMap(Int.init).map { min(16, max(1, $0)) } ?? 1
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
        } else { app.route = .section(.machines) }
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
