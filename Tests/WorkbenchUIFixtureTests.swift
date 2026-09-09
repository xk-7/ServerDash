import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import ServerDash

/// Generates review artifacts from isolated, synthetic data. No connections are opened.
@MainActor final class WorkbenchUIFixtureTests: XCTestCase {
    private let output = URL(fileURLWithPath: "/tmp/serverdash-workbench-ui-qa", isDirectory: true)
    // SwiftUI can release Query observers after a hosted XCTest window disappears.
    // Keep the handful of isolated stores alive for the test process, matching the
    // application's container lifetime instead of leaving observers with a dead store.
    private static var retainedContainers: [ModelContainer] = []

    private func fixtureContainer() throws -> ModelContainer {
        let container = try PersistenceController.makeInMemoryContainer()
        Self.retainedContainers.append(container)
        return container
    }

    func testWorkbenchLayoutsLightDarkAndNarrowFixtures() async throws {
        let standard = UserDefaults.standard
        let savedInterval = standard.object(forKey: "refreshInterval")
        let savedConfigured = standard.object(forKey: "refreshIntervalConfigured")
        standard.set(0.0, forKey: "refreshInterval")
        standard.set(true, forKey: "refreshIntervalConfigured")
        defer {
            restore(savedInterval, key: "refreshInterval", defaults: standard)
            restore(savedConfigured, key: "refreshIntervalConfigured", defaults: standard)
        }
        let suite = "ServerDash.WorkbenchUIFixture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "hideIPInformation")
        defaults.set(true, forKey: "disableLocationLookup")
        defaults.set(0.0, forKey: "refreshInterval")
        defaults.set(true, forKey: "refreshIntervalConfigured")
        defaults.set(true, forKey: "monitor.hideSpecialFilesystems")
        defaults.set(true, forKey: "monitor.hideDockerMounts")
        defaults.set(true, forKey: "monitor.hideVirtualInterfaces")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let container = try fixtureContainer()
        let app = fixtureApp()
        let servers = try populate(container)
        XCTAssertTrue(servers.allSatisfy { !$0.enableDashboardMonitor })
        app.route = .section(.machines)
        app.bootstrap(servers: servers, context: container.mainContext)
        let snapshot = monitoringSnapshot()
        let history = monitoringHistory(snapshot.capturedAt)
        for (index, server) in servers.enumerated() {
            var state = ServerRenderState(status: [.online, .connecting, .failed, .offline, .unknown][index % 5])
            if index == 0 || index == 3 {
                state.snapshot = snapshot
                if index == 3 { state.snapshot.capturedAt = snapshot.capturedAt.addingTimeInterval(-600) }
                state.history = history
                state.lastSuccessfulMonitorAt = state.snapshot.capturedAt
            }
            if index == 2 { state.error = "演示连接失败：超时" }
            app.runtime(for: server).publish(state)
        }
        let layout = MonitorLayoutStore(defaults: defaults)
        var artifacts: [FixtureArtifact] = []
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let theme = dark ? "dark" : "light"
            defaults.set(theme, forKey: "appAppearance")
            for mode in ["grid", "list"] {
                defaults.set(mode, forKey: "machineViewMode")
                for size in [NSSize(width: 900, height: 620), NSSize(width: 1440, height: 900), NSSize(width: 1920, height: 1080)] {
                    artifacts.append(try await render(
                        ContentView().modelContainer(container).environmentObject(app).environmentObject(layout)
                            .defaultAppStorage(defaults).environment(\.colorScheme, scheme).preferredColorScheme(scheme),
                        size: size, name: "machines-\(mode)-\(Int(size.width))-\(theme)", dark: dark))
                }
            }
            artifacts.append(try await render(
                SettingsView().modelContainer(container).environmentObject(app).environmentObject(layout)
                    .defaultAppStorage(defaults).environment(\.colorScheme, scheme).preferredColorScheme(scheme),
                size: NSSize(width: 1000, height: 740), name: "settings-\(theme)", dark: dark))
            artifacts.append(try await render(
                Form { MonitoringFilterSettingsView() }.formStyle(.grouped)
                    .defaultAppStorage(defaults).environment(\.colorScheme, scheme),
                size: NSSize(width: 640, height: 460), name: "monitoring-settings-\(theme)", dark: dark))

            let server = try XCTUnwrap(servers.first)
            let controller = TerminalSessionController(server: server, attachProcess: false)
            controller.status = .connected
            let runtime = ServerRuntimeState(serverID: server.id,
                initial: ServerRenderState(status: .online, snapshot: snapshot, history: history, lastSuccessfulMonitorAt: snapshot.capturedAt))
            for section in [TerminalInspectorSection.status, .cpu, .gpu, .memory, .disk, .network] {
                artifacts.append(try await render(
                    TerminalInspectorView(server: server, controller: controller, runtime: runtime,
                        snippets: [], refreshInterval: 5, selectedTab: .constant(section.rawValue), onInsert: { _ in }, onRun: { _ in })
                        .modelContainer(container).environmentObject(app).defaultAppStorage(defaults)
                        .environment(\.colorScheme, scheme).preferredColorScheme(scheme),
                    size: NSSize(width: 390, height: 820), name: "inspector-\(section.rawValue)-\(theme)", dark: dark))
            }
            let missing = ServerRuntimeState(serverID: server.id,
                initial: ServerRenderState(status: dark ? .failed : .unknown,
                    error: dark ? "演示采集失败：服务器未返回监控响应" : nil))
            artifacts.append(try await render(
                TerminalInspectorView(server: server, controller: controller, runtime: missing,
                    snippets: [], refreshInterval: 5, selectedTab: .constant("status"), onInsert: { _ in }, onRun: { _ in })
                    .modelContainer(container).environmentObject(app).defaultAppStorage(defaults)
                    .environment(\.colorScheme, scheme).preferredColorScheme(scheme),
                size: NSSize(width: 340, height: 620), name: "inspector-\(dark ? "failed" : "missing")-\(theme)", dark: dark))

            let empty = try fixtureContainer()
            let emptyApp = fixtureApp(); emptyApp.route = .section(.machines)
            defaults.set("grid", forKey: "machineViewMode")
            artifacts.append(try await render(
                ContentView().modelContainer(empty).environmentObject(emptyApp).environmentObject(layout)
                    .defaultAppStorage(defaults).environment(\.colorScheme, scheme).preferredColorScheme(scheme),
                size: NSSize(width: 900, height: 620), name: "machines-empty-900-\(theme)", dark: dark))
            XCTAssertTrue(emptyApp.terminalRegistry.controllers.isEmpty)
            XCTAssertTrue(emptyApp.fileControllers.isEmpty)
        }
        XCTAssertTrue(app.terminalRegistry.controllers.isEmpty)
        XCTAssertTrue(app.workbenchSessions.controllers.isEmpty)
        XCTAssertTrue(app.fileControllers.isEmpty)
        XCTAssertTrue(app.rdpControllers.isEmpty)
        try JSONEncoder().encode(artifacts).write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        print("Workbench UI fixtures (\(artifacts.count) PNGs): \(output.path)")
        // Do not call AppState.shutdown(): it deliberately cleans process-wide credential material.
        // These fixture states own no sessions, timers or credentials; their view/window ownership ends here.
    }

    func testOneFourAndSixteenPaneLifecyclesPreserveNativeSessions() async throws {
        let standard = UserDefaults.standard
        let interval = standard.object(forKey: "refreshInterval")
        let configured = standard.object(forKey: "refreshIntervalConfigured")
        standard.set(0.0, forKey: "refreshInterval"); standard.set(true, forKey: "refreshIntervalConfigured")
        defer {
            restore(interval, key: "refreshInterval", defaults: standard)
            restore(configured, key: "refreshIntervalConfigured", defaults: standard)
        }
        let suite = "ServerDash.WorkbenchLifecycleFixture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "disableLocationLookup")
        defaults.set("grid", forKey: "machineViewMode")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checkpoints: [String] = []
        // Match application lifetime: the database and AppState outlive all window and
        // session presentations. Vary the session count without replacing SwiftData stores.
        let container = try fixtureContainer()
        let server = ServerRecord(name: "SSH 隔离工作台", host: "192.0.2.90", username: "fixture", enableDashboardMonitor: false)
        container.mainContext.insert(server); try container.mainContext.save()
        let app = fixtureApp(); app.bootstrap(servers: [server], context: container.mainContext)
        let registry = app.terminalRegistry, workspace = registry.workspace
        defer { registry.terminateAll() }
        for count in [1, 4, 16] {
            let controllers = (0..<count).map { _ in registry.open(for: server, forceNew: true, startImmediately: false) }
            let first = try XCTUnwrap(controllers.first)
            for (index, controller) in controllers.enumerated() {
                controller.status = .connected
                var profile = TerminalAppearanceProfile.default; profile.fontSize = 11; profile.cursorBlinkEnabled = false
                controller.applyAppearance(profile, dark: false)
                if index > 0 { XCTAssertTrue(workspace.split(first.id, inserting: controller.id, axis: index.isMultiple(of: 2) ? .right : .below)) }
                controller.hostView.feedLocalOutput("\u{1b}[36mPanel \(index + 1) · Ubuntu fixture\u{1b}[0m\r\nCPU 3.2%   MEM 1.4 GB\r\n\u{1b}[32mP\(index + 1)$\u{1b}[0m ")
            }
            workspace.arrangeGrid(); workspace.select(pane: first.id)
            app.route = .section(.terminal)
            let snapshot = monitoringSnapshot()
            app.runtime(for: server).publish(ServerRenderState(status: .online, snapshot: snapshot, history: monitoringHistory(snapshot.capturedAt)))
            let presentation = LifecycleFixturePresentation()
            let layout = MonitorLayoutStore(defaults: defaults)
            let content = LifecycleFixtureView(presentation: presentation, app: app, server: server, controller: first,
                runtime: app.runtime(for: server))
                .modelContainer(container).environmentObject(app).environmentObject(layout).defaultAppStorage(defaults)
            let hosting = NSHostingController(rootView: content)
            let root = hosting.view
            root.appearance = NSAppearance(named: .aqua)
            let size = NSSize(width: 1440, height: 900)
            root.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentViewController = hosting
            window.title = "ServerDash · \(count) 面板隔离验收"
            window.center(); window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentViewController = nil; window.close() }
            let generations = Dictionary(uniqueKeysWithValues: controllers.map { ($0.id, $0.connectionGeneration) })
            let dates = Dictionary(uniqueKeysWithValues: controllers.map { ($0.id, $0.createdAt) })
            let hosts = controllers.map { ObjectIdentifier($0.hostView) }
            let terminals = try controllers.map { try XCTUnwrap($0.hostView.subviews.compactMap { $0 as? ServerDashTerminalView }.first) }
            func assertStable(_ step: String) {
                XCTAssertEqual(registry.controllers.count, count, step)
                XCTAssertEqual(Set(workspace.selectedTab?.layout.panes ?? []), Set(controllers.map(\.id)), step)
                for (index, controller) in controllers.enumerated() {
                    XCTAssertTrue(registry.controller(for: controller.id) === controller, step)
                    XCTAssertEqual(ObjectIdentifier(controller.hostView), hosts[index], step)
                    XCTAssertEqual(controller.connectionGeneration, generations[controller.id], step)
                    XCTAssertEqual(controller.createdAt, dates[controller.id], step)
                    XCTAssertEqual(controller.status, .connected, step)
                    XCTAssertNil(controller.connectionTask, step)
                    XCTAssertFalse(terminals[index].process.running, step)
                }
                XCTAssertTrue(app.fileControllers.isEmpty, step)
                XCTAssertTrue(app.rdpControllers.isEmpty, step)
                checkpoints.append("\(count) panels: \(step)")
            }
            func settle(_ step: String) async throws {
                try await Task.sleep(for: .milliseconds(240))
                root.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                assertStable(step)
            }
            try await settle("mounted terminal workspace")
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(root.window === window)
            for terminal in terminals {
                XCTAssertTrue(terminal.window === window)
                XCTAssertTrue(window.makeFirstResponder(terminal), "Every visible SSH pane accepts keyboard focus")
                XCTAssertTrue(window.firstResponder === terminal)
            }
            var keyViews = Set<ObjectIdentifier>()
            for _ in 0..<(count + 4) {
                window.selectNextKeyView(nil)
                if let responder = window.firstResponder as? NSView { keyViews.insert(ObjectIdentifier(responder)) }
            }
            XCTAssertFalse(keyViews.isEmpty, "The native key-view loop must retain a reachable view")
            checkpoints.append("\(count) panels: each terminal accepts first responder; Tab reached \(keyViews.count) native views")
            let accessibility = accessibilityNodes(in: root)
            XCTAssertTrue(accessibility.contains { $0.role == "AXOutline" }, "The native navigation outline is exposed")
            XCTAssertTrue(accessibility.contains { $0.role == "AXMenuButton" }, "Native workbench menus are exposed")
            try JSONEncoder().encode(accessibility).write(to: output.appendingPathComponent("terminal-\(count)-accessibility.json"), options: .atomic)
            // In-process hosted SwiftUI windows expose native roles here, but can
            // return empty titles even for visible virtual AXStaticText elements.
            // This diagnostic cannot establish spoken labels or VoiceOver order.
            let accessibilityAudit = FixtureAccessibilityAudit(
                nodeCount: accessibility.count,
                nodesWithReadableLabels: accessibility.filter { !$0.label.isEmpty }.count,
                reachableNativeKeyViews: keyViews.count,
                labelCoverage: "incomplete: hosted SwiftUI virtual labels are not reliably available through the in-process AppKit API",
                manualVoiceOverRequired: true)
            try JSONEncoder().encode(accessibilityAudit).write(to: output.appendingPathComponent("terminal-\(count)-accessibility-audit.json"), options: .atomic)
            checkpoints.append("\(count) panels: native AX outline/menu roles verified; SwiftUI label coverage incomplete, manual VoiceOver required")
            app.route = .section(.machines); try await settle("navigate to machines")
            app.route = .section(.terminal); try await settle("return to terminal")
            workspace.toggleZoom(pane: first.id); try await settle("zoom active pane")
            workspace.toggleZoom(pane: first.id); try await settle("restore split panes")
            if case .split(let divider, _, _, _, _) = workspace.selectedTab?.layout {
                workspace.resize(divider: divider, ratio: 0.62); try await settle("resize split divider")
            }
            workspace.arrangeGrid(); try await settle("arrange native grid")
            presentation.inspectorVisible = true; try await settle("show native inspector")
            for section in ["cpu", "network", "memory"] {
                presentation.inspectorSection = section; try await settle("switch inspector \(section)")
            }
            presentation.scheme = .dark; defaults.set("dark", forKey: "appAppearance")
            window.appearance = NSAppearance(named: .darkAqua)
            root.appearance = NSAppearance(named: .darkAqua)
            try await settle("switch application to dark appearance")
            XCTAssertEqual(root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
            for controller in controllers {
                var profile = controller.appearanceProfile; profile.darkThemeID = "midnight"
                controller.applyAppearance(profile, dark: true)
            }
            try await settle("change terminal theme")
            presentation.inspectorVisible = false; try await settle("hide native inspector")
            for (index, controller) in controllers.enumerated() {
                let viewport = controller.hostView.recordingFrame(followOutput: true).screen.lines.flatMap(\.cells).map(\.text).joined()
                let buffer = String(decoding: terminals[index].getTerminal().getBufferAsData(), as: UTF8.self)
                try buffer.write(to: output.appendingPathComponent("terminal-\(count)-pane-\(index + 1)-buffer.txt"), atomically: true, encoding: .utf8)
                try viewport.write(to: output.appendingPathComponent("terminal-\(count)-pane-\(index + 1)-viewport.txt"), atomically: true, encoding: .utf8)
                // Resizing can move earlier output into scrollback. Compare the complete
                // buffer, removing only physical wraps introduced by terminal resizing.
                XCTAssertTrue(buffer.replacingOccurrences(of: "\n", with: "").contains("P\(index + 1)$"), "Pane output must survive presentation changes including scrollback")
            }
            if count == 16 {
                root.display()
                let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
                root.cacheDisplay(in: root.bounds, to: bitmap)
                let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(bytes.count, 3000)
                try bytes.write(to: output.appendingPathComponent("terminal-16-panels-dark.png"), options: .atomic)
            }
            registry.terminateAll()
            XCTAssertTrue(registry.controllers.isEmpty); XCTAssertTrue(workspace.tabs.isEmpty)
            XCTAssertTrue(terminals.allSatisfy { !$0.process.running })
            checkpoints.append("\(count) panels: explicit close releases all controllers and tabs")
        }
        try JSONEncoder().encode(checkpoints).write(to: output.appendingPathComponent("terminal-lifecycle-checkpoints.json"), options: .atomic)
    }

    private func fixtureApp() -> AppState {
        let trust = HostTrustCoordinator(inspector: { _, _ in throw URLError(.notConnectedToInternet) },
                                        truster: { _, _ in throw URLError(.notConnectedToInternet) })
        return AppState(trustCoordinator: trust, portForwardSupervisor: PortForwardSupervisor(),
                        terminalRegistry: TerminalSessionRegistry(attachProcess: false), fileServicesEnabled: false)
    }

    private func populate(_ container: ModelContainer) throws -> [ServerRecord] {
        let context = container.mainContext
        let production = MachineGroupRecord(name: "生产环境")
        context.insert(production)
        context.insert(MachineGroupRecord(name: "核心数据库", parentID: production.id))
        context.insert(MachineGroupRecord(name: "开发与测试"))
        context.insert(MachineTagRecord(name: "生产", colorName: "red"))
        context.insert(MachineTagRecord(name: "测试", colorName: "green"))
        context.insert(MachineTagRecord(name: "开发", colorName: "blue"))
        let names = ["01 上海生产环境核心数据库服务器 · 具有很长的中文名称", "02 应用网关", "03 持续集成测试", "04 备份服务器", "05 开发工作站"]
        let servers = names.enumerated().map { index, name in
            ServerRecord(name: name, host: "192.0.2.\(index + 10)", username: "operator",
                groupName: index == 0 ? "核心数据库" : (index < 3 ? "生产环境" : "开发与测试"),
                tagsText: index < 2 ? "生产" : "开发,测试",
                notes: index == 0 ? "每日备份 · 业务关键节点 · 维护窗口每周日 02:00" : (index == 2 ? "用于验证失败状态的独立演示记录" : ""),
                lastConnectedAt: index == 0 ? Date().addingTimeInterval(-120) : nil,
                enableDashboardMonitor: false, lastLatencyMS: index == 0 ? 19 : 0)
        }
        servers.forEach(context.insert)
        context.insert(try RDPConnectionRecord(name: "06 Windows 远程桌面", host: "192.0.2.40", username: "administrator", groupName: "生产环境", tagsText: "生产"))
        context.insert(VNCConnectionRecord(name: "07 系统屏幕共享", host: "192.0.2.50", groupName: "开发与测试", notes: "外部客户端启动状态"))
        context.insert(SerialConnectionRecord(name: "08 ESP32 实验台串口", devicePath: "", groupName: "开发与测试", tagsText: "开发"))
        context.insert(CommandSnippetRecord(title: "查看磁盘使用", command: "df -h", category: "监控"))
        try context.save()
        return servers
    }

    private func monitoringSnapshot() -> ServerSnapshot {
        var result = ServerSnapshot.empty
        result.capturedAt = .now; result.cpuUsage = 32.4; result.coreCount = 16
        result.cpuModel = "AMD EPYC 7443P"; result.cpuTemperatureCelsius = 54
        result.cpuUserPercent = 21.6; result.cpuSystemPercent = 9.1; result.cpuIOWaitPercent = 1.7
        result.load1 = 1.30; result.load5 = 1.34; result.load15 = 1.41
        result.cpuCores = (0..<16).map { .init(index: $0, user: Double(($0 * 7) % 50), system: 4, nice: 0, ioWait: 1, steal: 0) }
        let gib = 1024.0 * 1024 * 1024
        result.memoryUsedBytes = 10.4 * gib; result.memoryTotalBytes = 32 * gib
        result.memoryCachedBytes = 5.6 * gib; result.memoryFreeBytes = 16 * gib
        result.swapUsedBytes = 0.15 * gib; result.swapTotalBytes = 4 * gib
        result.diskUsedBytes = 180 * gib; result.diskTotalBytes = 500 * gib
        result.distribution = "Ubuntu 24.04 LTS"; result.kernel = "Linux 6.8.0"; result.uptime = "51 天 05:08"
        result.processCount = 320; result.loggedInUsers = 1
        result.topProcesses = [.init(name: "postgres", pid: 12584, cpu: 22.4, memory: 8.2, user: "postgres", arguments: "/usr/lib/postgresql/16/bin/postgres", threadCount: 4),
                               .init(name: "nginx", pid: 12611, cpu: 7.8, memory: 1.2, user: "www-data", arguments: "nginx: worker process", threadCount: 1),
                               .init(name: "serverdash-agent", pid: 12800, cpu: 1.7, memory: 0.6, user: "operator", threadCount: 2)]
        result.processes = result.topProcesses
        result.filesystems = [.init(device: "/dev/vda1", mountPoint: "/", filesystemType: "ext4", usedBytes: 180 * gib, totalBytes: 500 * gib),
                              .init(device: "/dev/vdb1", mountPoint: "/home", filesystemType: "ext4", usedBytes: 62 * gib, totalBytes: 250 * gib)]
        result.diskIO = [.init(device: "vda", readBytesPerSecond: 819200, writeBytesPerSecond: 204800, readIOPS: 73, writeIOPS: 14, readLatencyMilliseconds: 1.2, writeLatencyMilliseconds: 2.1, lifetimeReadBytes: 2000 * gib, lifetimeWriteBytes: 500 * gib)]
        result.gpus = [.init(index: 0, uuid: "GPU-fixture-01", name: "NVIDIA RTX 4090", utilization: 67, memoryUsedBytes: 8.5 * gib, memoryTotalBytes: 24 * gib, fanPercent: 44, temperatureCelsius: 62, powerWatts: 185, powerLimitWatts: 450)]
        result.gpuProcesses = [.init(gpuID: "GPU-fixture-01", pid: 1834, name: "python · 数据分析", memoryBytes: 8.5 * gib)]
        result.networkInterfaces = [.init(name: "eth0", receivedBytes: 700 * gib, sentBytes: 100 * gib, downloadBytesPerSecond: 819200, uploadBytesPerSecond: 204800, isActive: true),
                                    .init(name: "eth1", receivedBytes: 2 * gib, sentBytes: gib, downloadBytesPerSecond: 4096, uploadBytesPerSecond: 2048)]
        result.activeNetworkInterface = "eth0"; result.downloadBytesPerSecond = 819200; result.uploadBytesPerSecond = 204800
        result.sockets = .init(total: 195, tcp: 83, udp: 12, listening: 3, timeWait: 8)
        result.fileHandlesUsed = 1472; result.fileHandlesLimit = 65536
        result.listeningPortsAvailable = true
        result.listeningPorts = [.init(transport: "tcp", address: "192.0.2.10:22", process: "sshd (pid 918)"),
                                 .init(transport: "tcp", address: "192.0.2.10:443", process: "nginx (pid 12611)"),
                                 .init(transport: "udp", address: "192.0.2.10:53", process: "systemd-resolved")]
        return result
    }

    private func monitoringHistory(_ date: Date) -> [MetricPoint] {
        (0..<21).map { index in
            let wave = sin(Double(index) * 0.4)
            return MetricPoint(date: date.addingTimeInterval(Double(index - 20) * 3), cpu: 24 + wave * 8,
                               memory: 32 + wave, download: 700_000 + wave * 220_000, upload: 180_000 + wave * 80_000)
        }
    }

    private func render<Content: View>(_ content: Content, size: NSSize, name: String, dark: Bool) async throws -> FixtureArtifact {
        // A hosting controller and a key titled window give native sidebar Lists their
        // normal AppKit lifecycle; a detached/borderless hosting view can omit List layers.
        let hosting = NSHostingController(rootView: content.frame(width: size.width, height: size.height))
        let root = hosting.view
        root.frame = NSRect(origin: .zero, size: size)
        root.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting; window.appearance = root.appearance
        window.title = "ServerDash · 隔离界面夹具"
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentViewController = nil; window.contentView = nil; window.close() }
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(650))
        root.layoutSubtreeIfNeeded(); window.displayIfNeeded(); root.display()
        XCTAssertTrue(root.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(root.bounds.width, size.width, accuracy: 1)
        XCTAssertEqual(root.bounds.height, size.height, accuracy: 1)
        try captureSidebarTable(in: root, name: name)
        let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
        root.cacheDisplay(in: root.bounds, to: bitmap)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(bytes.count, 3000, "A UI fixture must contain rendered content")
        try bytes.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
        return FixtureArtifact(name: name, width: Int(size.width), height: Int(size.height), pixelsWide: bitmap.pixelsWide, pixelsHigh: bitmap.pixelsHigh, nativeTableRows: nativeTableRows(in: root), accessibility: accessibilityNodes(in: root))
    }

    private func captureSidebarTable(in root: NSView, name: String) throws {
        func tables(in view: NSView) -> [NSTableView] {
            if let table = view as? NSTableView { return [table] }
            return view.subviews.flatMap { tables(in: $0) }
        }
        guard let table = tables(in: root).first(where: {
            let frame = root.convert($0.bounds, from: $0)
            return $0.numberOfRows > 0 && frame.minX < 120 && frame.width < 300
        }) else { return }
        // Capture the actual native List child separately. This avoids treating
        // an NSVisualEffectView compositor mask in cacheDisplay as missing UI.
        table.layoutSubtreeIfNeeded(); table.display()
        let visible = table.visibleRect.intersection(table.bounds)
        guard visible.width > 0, visible.height > 0 else { return }
        let rep = try XCTUnwrap(table.bitmapImageRepForCachingDisplay(in: visible))
        table.cacheDisplay(in: visible, to: rep)
        let bytes = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try bytes.write(to: output.appendingPathComponent(name + "-sidebar-table.png"), options: .atomic)
    }

    private func accessibilityNodes(in root: NSView) -> [FixtureAccessibilityNode] {
        var pending: [Any] = NSAccessibility.unignoredChildrenForOnlyChild(from: root) + [root]
        var visited = Set<ObjectIdentifier>()
        var result: [FixtureAccessibilityNode] = []
        while !pending.isEmpty && result.count < 500 {
            let item = pending.removeFirst()
            guard let object = item as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let accessible = object as? NSAccessibilityProtocol
            func firstNonempty(_ values: [String?]) -> String {
                values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
            }
            // SwiftUI's virtual accessibility children may implement AppKit's informal
            // NSObject accessibility API without conforming to NSAccessibilityProtocol.
            let formalRole = accessible?.accessibilityRole()?.rawValue
            let legacyRole = object.accessibilityAttributeValue(.role) as? String
            let role = firstNonempty([formalRole == NSAccessibility.Role.unknown.rawValue ? nil : formalRole, legacyRole])
            let label = firstNonempty([accessible?.accessibilityLabel(), accessible?.accessibilityTitle(),
                object.accessibilityAttributeValue(.title) as? String,
                object.accessibilityAttributeValue(.description) as? String,
                accessible?.accessibilityHelp(), object.accessibilityAttributeValue(.help) as? String])
            if !role.isEmpty && role != NSAccessibility.Role.unknown.rawValue { result.append(.init(role: role, label: label)) }
            let children = (accessible?.accessibilityChildren() ?? []) + (object.accessibilityAttributeValue(.children) as? [Any] ?? [])
            pending.append(contentsOf: NSAccessibility.unignoredChildren(from: children))
            pending.append(contentsOf: children)
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }

    private func nativeTableRows(in view: NSView) -> [Int] {
        (view as? NSTableView).map { [$0.numberOfRows] } ?? view.subviews.flatMap { nativeTableRows(in: $0) }
    }

    private func restore(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }

    private struct FixtureArtifact: Codable {
        let name: String
        let width: Int
        let height: Int
        let pixelsWide: Int
        let pixelsHigh: Int
        let nativeTableRows: [Int]
        let accessibility: [FixtureAccessibilityNode]
    }

    private struct FixtureAccessibilityNode: Codable {
        let role: String
        let label: String
    }

    private struct FixtureAccessibilityAudit: Codable {
        let nodeCount: Int
        let nodesWithReadableLabels: Int
        let reachableNativeKeyViews: Int
        let labelCoverage: String
        let manualVoiceOverRequired: Bool
    }
}

@MainActor private final class LifecycleFixturePresentation: ObservableObject {
    @Published var scheme: ColorScheme = .light
    @Published var inspectorVisible = false
    @Published var inspectorSection = "status"
}

/// Uses a controlled native inspector presentation because detached XCTest windows have no SceneStorage lifecycle.
private struct LifecycleFixtureView: View {
    @ObservedObject var presentation: LifecycleFixturePresentation
    @ObservedObject var app: AppState
    let server: ServerRecord
    let controller: TerminalSessionController
    @ObservedObject var runtime: ServerRuntimeState
    var body: some View {
        ContentView()
            .inspector(isPresented: $presentation.inspectorVisible) {
                TerminalInspectorView(server: server, controller: controller, runtime: runtime, snippets: [],
                    refreshInterval: 5, selectedTab: $presentation.inspectorSection, onInsert: { _ in }, onRun: { _ in })
                    .inspectorColumnWidth(min: 320, ideal: 340, max: 400)
            }
            .environment(\.colorScheme, presentation.scheme)
            .preferredColorScheme(presentation.scheme)
    }
}
